# Each new migrations image runs once, before its service's server rolls. A finished Job stays as its
# record. It runs only once the operators' kinds exist, since it reads the database's Secret.
resource "kubernetes_job_v1" "migrations" {
  for_each = var.custom_resources ? toset([for service, roles in local.release_roles : service if contains(roles, "migrations")]) : toset([])

  metadata {
    name      = "migrations-${substr(trimprefix(local.release_images["${each.key}/migrations"].digest, "sha256:"), 0, 12)}"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
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
          image = local.release_image["${each.key}/migrations"]

          dynamic "env" {
            for_each = merge(local.database_env[each.key], local.downtime_env[each.key], { SSL_CERT_DIR = "/etc/ssl/certs:/etc/database-ca" })

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

          volume_mount {
            name       = "database-ca"
            mount_path = "/etc/database-ca"
            read_only  = true
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

        # The migrations trust the database's CA as the server does.
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
    create = "10m"
  }

  depends_on = [kubernetes_manifest.database, kubernetes_network_policy_v1.database_clients]
}

moved {
  from = kubernetes_job_v1.json_keys_migrations[0]
  to   = kubernetes_job_v1.migrations["json-keys"]
}
