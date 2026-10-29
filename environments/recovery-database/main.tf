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

  # The drill restores with production's committed pins: the add-on images, the database's sizes and
  # backup name, and its release image.
  production    = provider::terraform::decode_tfvars(file("${path.module}/../production/cluster/terraform.tfvars"))
  database      = local.production.databases[var.recovery.service]
  release_image = provider::terraform::decode_tfvars(file("${path.module}/../production/foundation/terraform.tfvars")).database_images[var.recovery.service]

  # Each image pulls through the drill's caches, as production's pull through its own.
  image_parts = { for name, reference in merge(local.production.addon_images, { database = local.release_image }) : name => regex("^(?P<host>[^/]+)/(?P<path>[^:]+):(?P<tag>.+)$", reference) }
  images = {
    for name, parts in local.image_parts : name => {
      repository = "${local.cluster.image_registries[parts.host]}/${parts.path}"
      tag        = parts.tag
    }
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

resource "kubernetes_namespace_v1" "drill" {
  for_each = toset(["cert-manager", "cnpg-system", var.recovery.service])

  metadata {
    name   = each.key
    labels = local.pod_security
  }
}

module "database_operator" {
  source = "../../modules/database-operator"

  images = local.images
  namespaces = {
    cert_manager   = kubernetes_namespace_v1.drill["cert-manager"].metadata[0].name
    cloudnative_pg = kubernetes_namespace_v1.drill["cnpg-system"].metadata[0].name
  }
}

resource "kubernetes_manifest" "image" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ImageCatalog"
    metadata   = { name = "drill", namespace = kubernetes_namespace_v1.drill[var.recovery.service].metadata[0].name }
    spec       = { images = [{ major = 18, image = "${local.images.database.repository}:${local.images.database.tag}" }] }
  }

  depends_on = [module.database_operator]
}

# Production's backups, which the drill only reads: the restored database archives nothing.
resource "kubernetes_manifest" "backups" {
  manifest = {
    apiVersion = "barmancloud.cnpg.io/v1"
    kind       = "ObjectStore"
    metadata   = { name = "production", namespace = kubernetes_namespace_v1.drill[var.recovery.service].metadata[0].name }
    spec = {
      instanceSidecarConfiguration = { env = [{ name = "GOOGLE_CLOUD_PROJECT", value = local.management_project }] }
      configuration = {
        destinationPath   = "gs://${data.terraform_remote_state.bootstrap.outputs.barman_buckets[var.recovery.service]}/"
        googleCredentials = { gkeEnvironment = true }
      }
    }
  }

  depends_on = [module.database_operator]
}

# The apply waits until the database recovered to its target and serves. Its Kubernetes service
# account, named after it, is the one the drill cluster lets read the backups.
resource "kubernetes_manifest" "database" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata   = { name = "drill", namespace = kubernetes_namespace_v1.drill[var.recovery.service].metadata[0].name }
    spec = {
      instances       = 1
      imageCatalogRef = { apiGroup = "postgresql.cnpg.io", kind = "ImageCatalog", name = kubernetes_manifest.image.manifest.metadata.name, major = 18 }
      postgresUID     = 999
      postgresGID     = 999
      resources       = { requests = { cpu = local.database.cpu, memory = local.database.memory }, limits = { memory = local.database.memory } }
      storage         = { size = local.database.storage, storageClass = "standard-rwo" }

      postgresql = {
        shared_preload_libraries = contains(local.database.extensions, "pg_cron") ? ["pg_cron"] : []
        parameters = merge(
          { max_connections = tostring(local.database.max_connections) },
          contains(local.database.extensions, "pg_cron") ? { "cron.database_name" = "app", "cron.use_background_workers" = "on" } : {},
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
        plugin = { name = local.barman_plugin, parameters = { barmanObjectName = kubernetes_manifest.backups.manifest.metadata.name, serverName = local.production.backup_server_name } }
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
