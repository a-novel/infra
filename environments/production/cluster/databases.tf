# Each service's CloudNativePG database: a primary and a replica on separate nodes, archiving WAL to
# the service's Barman bucket. The cutover imported it from the service's retired database host
# (a-novel/infra#1207, a-novel/infra#1208). A new `backup_server_name` starts a new lineage, which
# recreates every database empty.
data "terraform_remote_state" "bootstrap" {
  backend = "gcs"
  config = {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "bootstrap"
  }
}

locals {
  barman_plugin      = "barman-cloud.cloudnative-pg.io"
  management_project = "a-novel-management-prod"
  # Each database's pods carry CloudNativePG's label for their Cluster, which is named `database`.
  database_pods = { "cnpg.io/cluster" = "database" }
  # The service's own workloads and jobs that connect to its database carry this label.
  database_clients = { "a-novel.io/database" = "client" }
  # A client's pods read the database's generated password at start, so they roll with each new
  # lineage, once its database serves.
  database_client_annotations = { "a-novel.io/database-lineage" = var.backup_server_name }
}

# A new lineage replaces it, and so each database and its backup schedule. Its creation waits four
# minutes, which separates a database from the one it replaces: the operator's objects for the old
# one share the new one's names until they are collected, and its instances wait up to three
# minutes for their clients before stopping. An overlap left one database trusting a CA another
# one generated.
resource "time_sleep" "database_lineage" {
  create_duration = "4m"
  triggers        = { lineage = var.backup_server_name }
}

# CloudNativePG reads PostgreSQL's major version from an image's tag, and ours carry the service's
# release version, so a catalog states it. Each image is the one its service root pins.
resource "kubernetes_manifest" "database_image" {
  for_each = var.custom_resources ? var.databases : {}

  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "ImageCatalog"
    metadata   = { name = "postgresql", namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name }
    spec       = { images = [{ major = 18, image = local.release_image["${each.key}/database"] }] }
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
      # Workload Identity gives the sidecar a token but no project, which Cloud Storage's client
      # requires: the bucket's own project stands in.
      instanceSidecarConfiguration = { env = [{ name = "GOOGLE_CLOUD_PROJECT", value = local.management_project }] }
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

    ingress {
      from {
        pod_selector {
          match_labels = local.database_clients
        }
      }

      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }

    # Alloy scrapes each instance's metrics (alloy.tf).
    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = local.namespace["alloy"] }
        }
        pod_selector {
          match_labels = kubernetes_network_policy_v1.alloy.spec[0].pod_selector[0].match_labels
        }
      }

      ports {
        port     = "9187"
        protocol = "TCP"
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

import {
  for_each = var.adopted_databases

  to = kubernetes_manifest.database[each.value]
  id = "apiVersion=postgresql.cnpg.io/v1,kind=Cluster,namespace=${each.value},name=database"
}

# The service's clients reach its database, and nothing else through this policy.
resource "kubernetes_network_policy_v1" "database_clients" {
  for_each = var.databases

  metadata {
    name      = "database-clients"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = local.database_clients
    }
    policy_types = ["Egress"]

    egress {
      to {
        pod_selector {
          match_labels = local.database_pods
        }
      }

      ports {
        port     = "5432"
        protocol = "TCP"
      }
    }
  }
}

# A database's own metrics, from queries/<database>.yaml when it exists. Each instance rereads the
# ConfigMap, so a change restarts nothing.
resource "kubernetes_config_map_v1" "database_queries" {
  for_each = { for name in keys(var.databases) : name => "${path.module}/queries/${name}.yaml" if fileexists("${path.module}/queries/${name}.yaml") }

  metadata {
    name      = "database-queries"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
    labels    = { "cnpg.io/reload" = "" }
  }

  data = { "queries.yaml" = file(each.value) }
}

# CloudNativePG runs the queries as cnpg_metrics_exporter, which reads no table of ours, so the
# tables' owner grants it the columns queries/<database>.sql lists. An import leaves privileges out,
# and a migration may recreate a table, so the grants run again after each run of the migrations.
resource "kubernetes_job_v1" "database_grants" {
  for_each = var.custom_resources ? { for name in keys(kubernetes_config_map_v1.database_queries) : name => file("${path.module}/queries/${name}.sql") } : {}

  metadata {
    name      = "database-grants-${substr(sha256("${kubernetes_job_v1.migrations[each.key].metadata[0].name}\n${each.value}"), 0, 12)}"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  spec {
    backoff_limit           = 0
    active_deadline_seconds = 120

    template {
      metadata {
        labels = merge(local.database_clients, { "app.kubernetes.io/name" = "database-grants" })
      }

      spec {
        restart_policy                  = "Never"
        automount_service_account_token = false
        enable_service_links            = false

        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # psql sends the file as one statement list, which runs in a single transaction.
        container {
          name    = "grants"
          image   = local.release_image["${each.key}/database"]
          command = ["psql", "--no-psqlrc", "--command", each.value]

          dynamic "env" {
            for_each = {
              PGHOST        = local.database_env[each.key].POSTGRES_HOST
              PGPORT        = local.database_env[each.key].POSTGRES_PORT
              PGDATABASE    = local.database_env[each.key].POSTGRES_DATABASE
              PGSSLMODE     = "verify-full"
              PGSSLROOTCERT = "/etc/database-ca/ca.crt"
            }

            content {
              name  = env.key
              value = env.value
            }
          }

          dynamic "env" {
            for_each = { PGUSER = local.database_secret_env.POSTGRES_USER, PGPASSWORD = local.database_secret_env.POSTGRES_PASSWORD }

            content {
              name = env.key

              value_from {
                secret_key_ref {
                  name = env.value.secret
                  key  = env.value.key
                }
              }
            }
          }

          volume_mount {
            name       = "database-ca"
            mount_path = "/etc/database-ca"
            read_only  = true
          }

          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { memory = "64Mi" }
          }

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
            secret_name = kubernetes_manifest.database_server_certificate[each.key].manifest.spec.secretName

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
    create = "5m"
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
    spec = merge(
      {
        instances           = 2
        imageCatalogRef     = { apiGroup = "postgresql.cnpg.io", kind = "ImageCatalog", name = kubernetes_manifest.database_image[each.key].manifest.metadata.name, major = 18 }
        postgresUID         = 999
        postgresGID         = 999
        primaryUpdateMethod = "switchover"
        affinity            = { enablePodAntiAffinity = true, podAntiAffinityType = "required", topologyKey = "kubernetes.io/hostname" }
        resources           = { requests = { cpu = each.value.cpu, memory = each.value.memory }, limits = { memory = each.value.memory } }
        storage             = { size = each.value.storage, storageClass = "standard-rwo", resizeInUseVolumes = true }

        # Alloy scrapes each instance's metrics port (alloy.tf).
        inheritedMetadata = { annotations = { "k8s.grafana.com/scrape" = "true", "k8s.grafana.com/metrics.portName" = "metrics" } }

        # pg_cron runs GenAI's retention purge in background workers, since a job's own connection
        # would need a password.
        postgresql = {
          # Our CA signs every database's replication certificate, so each accepts only its own.
          pg_ident                 = ["cnpg_streaming_replica ${local.database_replication_names[each.key]} streaming_replica"]
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

        plugins = [{ name = local.barman_plugin, isWALArchiver = true, parameters = { barmanObjectName = kubernetes_manifest.database_backups[each.key].manifest.metadata.name, serverName = var.backup_server_name } }]

        # cert-manager's Secrets hold each certificate and the CA that signed it. The replica
        # authenticates with our CA's certificate, so the operator generates no client CA.
        certificates = {
          serverTLSSecret      = kubernetes_manifest.database_server_certificate[each.key].manifest.spec.secretName
          serverCASecret       = kubernetes_manifest.database_server_certificate[each.key].manifest.spec.secretName
          replicationTLSSecret = kubernetes_manifest.database_replication_certificate[each.key].manifest.spec.secretName
          clientCASecret       = kubernetes_manifest.database_replication_certificate[each.key].manifest.spec.secretName
        }
      },
      # The database's own queries, after CloudNativePG's, which its webhook would otherwise add
      # first.
      { for name, queries in kubernetes_config_map_v1.database_queries : "monitoring" => {
        customQueriesConfigMap = [
          { name = "cnpg-default-monitoring", key = "queries" },
          { name = queries.metadata[0].name, key = "queries.yaml" },
        ]
      } if name == each.key },
    )
  }

  # CloudNativePG's webhook adds its defaults to the PostgreSQL parameters, beside the provider's
  # own defaults.
  computed_fields = ["metadata.labels", "metadata.annotations", "spec.postgresql.parameters"]

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

  lifecycle {
    replace_triggered_by = [time_sleep.database_lineage]
  }

  depends_on = [kubernetes_network_policy_v1.database, time_sleep.database_lineage]
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

  # Each new lineage starts with a base backup, so its data has a recovery point at once.
  lifecycle {
    replace_triggered_by = [time_sleep.database_lineage]
  }
}
