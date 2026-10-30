data "terraform_remote_state" "drill" {
  backend = "gcs"
  config = {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "recovery-cluster/${var.recovery.project}"
  }
}

data "terraform_remote_state" "bootstrap" {
  backend = "gcs"
  config = {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "bootstrap"
  }
}

locals {
  cluster = data.terraform_remote_state.drill.outputs.cluster

  # The drill restores with production's committed pins: the add-on images, each database's sizes
  # and backup name, and its release image.
  production      = provider::terraform::decode_tfvars(file("${path.module}/../production/cluster/terraform.tfvars"))
  database_images = provider::terraform::decode_tfvars(file("${path.module}/../production/foundation/terraform.tfvars")).database_images

  # Each image pulls through the drill's caches, as production's pull through its own. The database
  # images go by their service's name. The drill runs only the database operators and the databases,
  # so it skips the images of registries it does not cache, such as Alloy's.
  image_parts = { for name, reference in merge(local.production.addon_images, local.database_images) : name => regex("^(?P<host>[^/]+)/(?P<path>[^:]+):(?P<tag>.+)$", reference) }
  images = {
    for name, parts in local.image_parts : name => {
      repository = "${local.cluster.image_registries[parts.host]}/${parts.path}"
      tag        = parts.tag
    } if contains(keys(local.cluster.image_registries), parts.host)
  }

  barman_plugin      = "barman-cloud.cloudnative-pg.io"
  management_project = "a-novel-management-prod"
  pod_security = {
    "pod-security.kubernetes.io/enforce"         = "restricted"
    "pod-security.kubernetes.io/enforce-version" = "latest"
  }
}

ephemeral "google_client_config" "ci" {}

provider "kubernetes" {
  host  = "https://${local.cluster.dns_endpoint}"
  token = ephemeral.google_client_config.ci.access_token
}

provider "helm" {
  helm_driver = "configmap"

  kubernetes = {
    host  = "https://${local.cluster.dns_endpoint}"
    token = ephemeral.google_client_config.ci.access_token
  }
}

# Destroying a namespace waits until its volume claims are gone, so their disks are deleted while
# the cluster still runs.
resource "kubernetes_namespace_v1" "drill" {
  for_each = setunion(["cert-manager", "cnpg-system"], var.recovery.services)

  metadata {
    name   = each.key
    labels = local.pod_security
  }
}

# The custom resources below plan only once this module installed their kinds, so recovery.yaml
# applies it first.
module "database_operator" {
  source = "../../modules/database-operator"

  images = { for name, image in local.images : name => image if contains(keys(local.production.addon_images), name) }
  namespaces = {
    cert_manager   = kubernetes_namespace_v1.drill["cert-manager"].metadata[0].name
    cloudnative_pg = kubernetes_namespace_v1.drill["cnpg-system"].metadata[0].name
  }
}

resource "kubernetes_manifest" "image" {
  for_each = var.recovery.services

  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ImageCatalog"
    metadata   = { name = "drill", namespace = kubernetes_namespace_v1.drill[each.key].metadata[0].name }
    spec       = { images = [{ major = 18, image = "${local.images[each.key].repository}:${local.images[each.key].tag}" }] }
  }

  depends_on = [module.database_operator]
}

# Production's backups, which the drill only reads: the restored databases archive nothing.
resource "kubernetes_manifest" "backups" {
  for_each = var.recovery.services

  manifest = {
    apiVersion = "barmancloud.cnpg.io/v1"
    kind       = "ObjectStore"
    metadata   = { name = "production", namespace = kubernetes_namespace_v1.drill[each.key].metadata[0].name }
    spec = {
      instanceSidecarConfiguration = { env = [{ name = "GOOGLE_CLOUD_PROJECT", value = local.management_project }] }
      configuration = {
        destinationPath   = "gs://${data.terraform_remote_state.bootstrap.outputs.barman_buckets[each.key]}/"
        googleCredentials = { gkeEnvironment = true }
      }
    }
  }

  depends_on = [module.database_operator]
}

# The apply waits until each database recovered to its target and serves. PostgreSQL fails a
# recovery that ends before its target. Its Kubernetes service account, named after it, is the one
# the drill cluster lets read the backups.
resource "kubernetes_manifest" "database" {
  for_each = var.recovery.services

  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata   = { name = "drill", namespace = kubernetes_namespace_v1.drill[each.key].metadata[0].name }
    spec = {
      instances       = 1
      imageCatalogRef = { apiGroup = "postgresql.cnpg.io", kind = "ImageCatalog", name = kubernetes_manifest.image[each.key].manifest.metadata.name, major = 18 }
      postgresUID     = 999
      postgresGID     = 999
      resources       = { requests = { cpu = local.production.databases[each.key].cpu, memory = local.production.databases[each.key].memory }, limits = { memory = local.production.databases[each.key].memory } }
      storage         = { size = local.production.databases[each.key].storage, storageClass = "standard-rwo" }

      postgresql = {
        shared_preload_libraries = contains(local.production.databases[each.key].extensions, "pg_cron") ? ["pg_cron"] : []
        parameters = merge(
          { max_connections = tostring(local.production.databases[each.key].max_connections) },
          contains(local.production.databases[each.key].extensions, "pg_cron") ? { "cron.database_name" = "app", "cron.use_background_workers" = "on" } : {},
        )
      }

      bootstrap = {
        recovery = merge(
          { source = "production", database = "app", owner = "app" },
          var.recovery.target_time == "" ? {} : { recoveryTarget = { targetTime = var.recovery.target_time } },
        )
      }

      externalClusters = [{
        name   = "production"
        plugin = { name = local.barman_plugin, parameters = { barmanObjectName = kubernetes_manifest.backups[each.key].manifest.metadata.name, serverName = local.production.backup_server_name } }
      }]
    }
  }

  # CloudNativePG's webhook adds its defaults to the PostgreSQL parameters, beside the provider's
  # own defaults.
  computed_fields = ["metadata.labels", "metadata.annotations", "spec.postgresql.parameters"]

  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }

  timeouts {
    create = "30m"
  }
}

# The drill passes once each restored database passes its checks. The check connects as the owner
# whose credentials CloudNativePG generated for the restore, over TLS it verifies against the
# database's own CA, and fails the apply at the first difference. Its log, which recovery.yaml
# prints, counts each table's rows.
resource "kubernetes_job_v1" "check" {
  for_each = var.recovery.services

  metadata {
    name      = "check"
    namespace = kubernetes_namespace_v1.drill[each.key].metadata[0].name
  }

  spec {
    backoff_limit           = 0
    active_deadline_seconds = 300

    template {
      metadata {}

      spec {
        restart_policy                  = "Never"
        automount_service_account_token = false
        enable_service_links            = false

        security_context {
          run_as_non_root = true
          run_as_user     = 999
          run_as_group    = 999

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "check"
          image   = one(kubernetes_manifest.image[each.key].manifest.spec.images).image
          command = ["psql", "--no-psqlrc", "--set=ON_ERROR_STOP=1", "--command", templatefile("${path.module}/check.sql.tftpl", { extensions = local.production.databases[each.key].extensions })]

          dynamic "env" {
            for_each = {
              PGHOST        = "${kubernetes_manifest.database[each.key].manifest.metadata.name}-rw.${kubernetes_namespace_v1.drill[each.key].metadata[0].name}.svc"
              PGDATABASE    = kubernetes_manifest.database[each.key].manifest.spec.bootstrap.recovery.database
              PGSSLMODE     = "verify-full"
              PGSSLROOTCERT = "/etc/database-ca/ca.crt"
            }

            content {
              name  = env.key
              value = env.value
            }
          }

          env {
            name = "PGUSER"

            value_from {
              secret_key_ref {
                name = "${kubernetes_manifest.database[each.key].manifest.metadata.name}-app"
                key  = "username"
              }
            }
          }

          env {
            name = "PGPASSWORD"

            value_from {
              secret_key_ref {
                name = "${kubernetes_manifest.database[each.key].manifest.metadata.name}-app"
                key  = "password"
              }
            }
          }

          volume_mount {
            name       = "database-ca"
            mount_path = "/etc/database-ca"
            read_only  = true
          }

          resources {
            requests = { cpu = "100m", memory = "128Mi" }
            limits   = { memory = "128Mi" }
          }

          # The provider sends runAsNonRoot=false for a container that leaves it unset, which
          # overrides the pod's and fails Pod Security.
          security_context {
            run_as_non_root            = true
            allow_privilege_escalation = false
            read_only_root_filesystem  = true

            capabilities {
              drop = ["ALL"]
            }
          }
        }

        volume {
          name = "database-ca"

          secret {
            secret_name = "${kubernetes_manifest.database[each.key].manifest.metadata.name}-ca"

            items {
              key  = "ca.crt"
              path = "ca.crt"
            }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "6m"
  }
}
