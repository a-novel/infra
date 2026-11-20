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
  # and backup name, and the database image each service's release file pins.
  production      = provider::terraform::decode_tfvars(file("${path.module}/../production/cluster/terraform.tfvars"))
  database_images = { for service in keys(local.production.databases) : service => provider::terraform::decode_tfvars(file("${path.module}/../production/cluster/releases/${service}.tfvars")).images.database }
  # Each database's archive of its current major, named as production's databases.tf names it.
  archives = { for service, database in local.production.databases : service => database.major > 18 ? "${local.production.backup_server_name}-pg${database.major}" : local.production.backup_server_name }

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

  # The Barman buckets live in production's management project.
  management_project = provider::terraform::decode_tfvars(file("${path.module}/../production/foundation/terraform.tfvars")).management_project_id

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
    spec       = { images = [{ major = local.production.databases[each.key].major, image = "${local.images[each.key].repository}:${local.images[each.key].tag}" }] }
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
      imageCatalogRef = { apiGroup = "postgresql.cnpg.io", kind = "ImageCatalog", name = kubernetes_manifest.image[each.key].manifest.metadata.name, major = local.production.databases[each.key].major }
      postgresUID     = 999
      postgresGID     = 999
      resources       = { requests = { cpu = local.production.databases[each.key].cpu, memory = local.production.databases[each.key].memory }, limits = { memory = local.production.databases[each.key].memory } }
      storage         = { size = local.production.databases[each.key].storage, storageClass = "standard-rwo" }

      postgresql = {
        # Refuse every connection without TLS. CloudNativePG's own rules, local and certificate
        # replication, come first, and its default password rule last.
        pg_hba                   = ["hostnossl all all all reject"]
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
        plugin = { name = module.database_operator.barman_plugin, parameters = { barmanObjectName = kubernetes_manifest.backups[each.key].manifest.metadata.name, serverName = local.archives[each.key] } }
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

# The drill passes once each restored database passes its checks. The check first proves the
# database refuses a connection without TLS. It then connects as the owner whose credentials
# CloudNativePG generated for the restore, over TLS it verifies against the database's own CA, and
# fails the apply at the first difference. Its log, which recovery.yaml prints, counts each table's
# rows.
module "check" {
  source   = "../../modules/cluster-job"
  for_each = var.recovery.services

  name      = "check"
  namespace = kubernetes_namespace_v1.drill[each.key].metadata[0].name
  # The PostgreSQL image's own unprivileged user.
  user = 999

  container_name = "check"
  image          = one(kubernetes_manifest.image[each.key].manifest.spec.images).image
  command        = ["sh", "-c", file("${path.module}/check.sh"), "check", templatefile("${path.module}/check.sql.tftpl", { extensions = local.production.databases[each.key].extensions })]
  env = {
    PGHOST        = "${kubernetes_manifest.database[each.key].manifest.metadata.name}-rw.${kubernetes_namespace_v1.drill[each.key].metadata[0].name}.svc"
    PGDATABASE    = kubernetes_manifest.database[each.key].manifest.spec.bootstrap.recovery.database
    PGSSLMODE     = "verify-full"
    PGSSLROOTCERT = "/etc/database-ca/ca.crt"
  }
  secret_env = [
    { name = "PGUSER", secret = "${kubernetes_manifest.database[each.key].manifest.metadata.name}-app", key = "username" },
    { name = "PGPASSWORD", secret = "${kubernetes_manifest.database[each.key].manifest.metadata.name}-app", key = "password" },
  ]
  ca_secret = "${kubernetes_manifest.database[each.key].manifest.metadata.name}-ca"
  resources = { cpu = "100m", memory = "128Mi" }

  active_deadline_seconds = 300
  timeout                 = "6m"
}
