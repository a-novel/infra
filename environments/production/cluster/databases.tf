# Each service's CloudNativePG database: a primary and a replica on separate nodes, archiving WAL to
# the service's Barman bucket. It holds no data until the cutover imports it (a-novel/infra#1207).
data "terraform_remote_state" "bootstrap" {
  backend = "gcs"
  config = {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "bootstrap"
  }
}

locals {
  barman_plugin = "barman-cloud.cloudnative-pg.io"
  # Each database's pods carry CloudNativePG's label for their Cluster, which is named `database`.
  database_pods = { "cnpg.io/cluster" = "database" }
}

# CloudNativePG reads PostgreSQL's major version from an image's tag, and ours carry the service's
# release version, so a catalog states it. Foundation names each image as its release pins it.
resource "kubernetes_manifest" "database_image" {
  for_each = var.custom_resources ? var.databases : {}

  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ImageCatalog"
    metadata   = { name = "postgresql", namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name }
    spec       = { images = [{ major = 18, image = local.cluster.database_images[each.key] }] }
  }
}

# Barman owns expiry inside the bucket, so it keeps 14 days of base backups and the WAL they need.
resource "kubernetes_manifest" "database_backups" {
  for_each = var.custom_resources ? var.databases : {}

  manifest = {
    apiVersion = "barmancloud.cnpg.io/v1"
    kind       = "ObjectStore"
    metadata   = { name = "backups", namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name }
    spec = {
      retentionPolicy = "14d"
      configuration = {
        destinationPath   = "gs://${data.terraform_remote_state.bootstrap.outputs.barman_buckets[each.key]}/"
        googleCredentials = { gkeEnvironment = true }
        wal               = { compression = "gzip" }
        data              = { compression = "gzip" }
      }
    }
  }
}

# The replica streams from the primary, and the operator checks each instance. Each instance reaches
# the API server, whose internal endpoint sits in the node range, and Cloud Storage through Google's
# restricted API addresses, with a Workload Identity token from the metadata server.
resource "kubernetes_network_policy_v1" "database" {
  for_each = var.databases

  metadata {
    name      = "database"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = local.database_pods
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        pod_selector {
          match_labels = local.database_pods
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "cnpg-system" }
        }
      }

      dynamic "ports" {
        for_each = ["5432", "8000"]
        content {
          port     = ports.value
          protocol = "TCP"
        }
      }
    }

    egress {
      to {
        pod_selector {
          match_labels = local.database_pods
        }
      }

      dynamic "ports" {
        for_each = ["5432", "8000"]
        content {
          port     = ports.value
          protocol = "TCP"
        }
      }
    }

    egress {
      dynamic "to" {
        for_each = concat([local.cluster.node_range], local.cluster.google_api_ranges)
        content {
          ip_block {
            cidr = to.value
          }
        }
      }

      ports {
        port     = "443"
        protocol = "TCP"
      }
    }

    egress {
      to {
        ip_block {
          cidr = "169.254.169.254/32"
        }
      }
      to {
        ip_block {
          cidr = "169.254.169.252/32"
        }
      }

      dynamic "ports" {
        for_each = ["80", "988"]
        content {
          port     = ports.value
          protocol = "TCP"
        }
      }
    }
  }
}

# The deploy waits until both instances serve and WAL reaches Barman, which proves the image runs
# under CloudNativePG (a-novel/infra#1194). Updates switch the replica over instead of restarting
# the primary. CloudNativePG generates the credentials, in the `database-app` Secret.
resource "kubernetes_manifest" "database" {
  for_each = var.custom_resources ? var.databases : {}

  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata   = { name = "database", namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name }
    spec = {
      instances           = 2
      imageCatalogRef     = { apiGroup = "postgresql.cnpg.io", kind = "ImageCatalog", name = kubernetes_manifest.database_image[each.key].manifest.metadata.name, major = 18 }
      postgresUID         = 999
      postgresGID         = 999
      primaryUpdateMethod = "switchover"
      affinity            = { enablePodAntiAffinity = true, podAntiAffinityType = "required", topologyKey = "kubernetes.io/hostname" }
      resources           = { requests = { cpu = each.value.cpu, memory = each.value.memory }, limits = { memory = each.value.memory } }
      storage             = { size = each.value.storage, storageClass = "standard-rwo", resizeInUseVolumes = true }

      # pg_cron runs GenAI's retention purge in background workers, since a job's own connection
      # would need a password.
      postgresql = {
        shared_preload_libraries = contains(each.value.extensions, "pg_cron") ? ["pg_cron"] : []
        parameters = merge(
          { max_connections = tostring(each.value.max_connections) },
          contains(each.value.extensions, "pg_cron") ? { "cron.database_name" = "app", "cron.use_background_workers" = "on" } : {},
        )
      }

      bootstrap = {
        initdb = {
          database = "app"
          owner    = "app"
          postInitApplicationSQL = concat(
            [for extension in each.value.extensions : "CREATE EXTENSION IF NOT EXISTS \"${extension}\""],
            contains(each.value.extensions, "pg_cron") ? ["GRANT USAGE ON SCHEMA cron TO app"] : [],
          )
        }
      }

      plugins = [{ name = local.barman_plugin, isWALArchiver = true, parameters = { barmanObjectName = kubernetes_manifest.database_backups[each.key].manifest.metadata.name } }]
    }
  }

  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
    condition {
      type   = "ContinuousArchiving"
      status = "True"
    }
  }

  timeouts {
    create = "20m"
    update = "20m"
  }

  depends_on = [kubernetes_network_policy_v1.database]
}

# A daily base backup, from the replica. The first runs at once.
resource "kubernetes_manifest" "database_schedule" {
  for_each = var.custom_resources ? var.databases : {}

  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ScheduledBackup"
    metadata   = { name = "daily", namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name }
    spec = {
      schedule             = "0 0 3 * * *"
      immediate            = true
      backupOwnerReference = "self"
      cluster              = { name = kubernetes_manifest.database[each.key].manifest.metadata.name }
      method               = "plugin"
      pluginConfiguration  = { name = local.barman_plugin }
      target               = "prefer-standby"
    }
  }
}

# Every plan and drift check warns when a database has no base backup from the last two days.
check "databases_back_up" {
  data "kubernetes_resources" "databases" {
    api_version = "postgresql.cnpg.io/v1"
    kind        = "Cluster"
  }

  assert {
    condition = alltrue([for database in coalesce(data.kubernetes_resources.databases.objects, []) :
      timecmp(timeadd(try(database.status.lastSuccessfulBackup, "1970-01-01T00:00:00Z"), "48h"), plantimestamp()) > 0
    ])
    error_message = "A database has no base backup from the last two days."
  }
}
