# JSON Keys on the cluster, which serves no one until the cutover (a-novel/.github#522). Its pods run
# only once the operators' kinds exist, since they read the database's and External Secrets' Secrets.
locals {
  json_keys_env = merge(local.database_env, local.downtime_env["json-keys"], {
    # Signing reads keys from a cache, so a few connections serve every pod.
    POSTGRES_MAX_OPEN_CONNS = "5"
    POSTGRES_MAX_IDLE_CONNS = "2"
    GRPC_PORT               = "8080"
    GOMEMLIMIT              = "400MiB"
    # Alloy carries the telemetry once it runs (a-novel/infra#1206).
    OTEL                   = "false"
    SERVICE_TOKEN_ISSUER   = local.service_token_issuer
    SERVICE_TOKEN_AUDIENCE = "json-keys"
    SERVICE_TOKEN_CALLERS  = "system:serviceaccount:authentication:rest,system:serviceaccount:json-keys:smoke"
  })
}

# Each new migrations image runs once, before the server rolls. A finished Job stays as its record.
resource "kubernetes_job_v1" "json_keys_migrations" {
  count = var.custom_resources ? 1 : 0

  metadata {
    name      = "migrations-${substr(trimprefix(local.release_images["json-keys/migrations"].digest, "sha256:"), 0, 12)}"
    namespace = kubernetes_namespace_v1.service["json-keys"].metadata[0].name
  }

  spec {
    backoff_limit           = 0
    active_deadline_seconds = 600

    template {
      metadata {
        labels = merge(local.database_clients, { "app.kubernetes.io/name" = "migrations" })
      }

      spec {
        restart_policy                  = "Never"
        automount_service_account_token = false

        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "migrations"
          image = local.release_image["json-keys/migrations"]

          dynamic "env" {
            for_each = merge(local.database_env, local.downtime_env["json-keys"])

            content {
              name  = env.key
              value = env.value
            }
          }

          dynamic "env" {
            for_each = local.database_secret_env

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

          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "256Mi" }
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
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "10m"
  }

  depends_on = [kubernetes_manifest.database, kubernetes_network_policy_v1.database_clients]
}

module "json_keys_grpc" {
  source = "../../../modules/cluster-workload"
  count  = var.custom_resources ? 1 : 0

  name       = "grpc"
  namespace  = kubernetes_namespace_v1.service["json-keys"].metadata[0].name
  image      = local.release_image["json-keys/grpc"]
  port       = 8080
  env        = local.json_keys_env
  secret_env = merge(local.database_secret_env, { APP_MASTER_KEY = { secret = "secrets", key = "APP_MASTER_KEY" } })
  resources  = { cpu = "100m", memory = "512Mi" }
  replicas   = { min = 2, max = 2 }
  labels     = local.database_clients

  depends_on = [kubernetes_job_v1.json_keys_migrations, kubernetes_manifest.secrets]
}

# Authentication's API and JSON Keys' smoke check call the server, which reaches the issuer's keys
# through Google's restricted API addresses.
resource "kubernetes_network_policy_v1" "json_keys_grpc" {
  metadata {
    name      = "grpc"
    namespace = kubernetes_namespace_v1.service["json-keys"].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "grpc" }
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "authentication" }
        }
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "rest" }
        }
      }
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "smoke" }
        }
      }

      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }

    egress {
      dynamic "to" {
        for_each = local.cluster.google_api_ranges

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
  }
}
