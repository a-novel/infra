# The jobs that run outside a deploy: those their schedules start, and the maintenance operations the
# named operators start. A failed run is not retried: the next one takes over, or the operator runs
# it again.
locals {
  scheduled_jobs = {
    # JSON Keys signs nothing until a first run creates each usage's key. Later runs rotate a key once
    # its interval has elapsed.
    rotate-keys = {
      service    = "json-keys"
      image      = "json-keys/rotatekeys"
      schedule   = "10 * * * *"
      suspend    = false
      args       = []
      env        = {}
      secret_env = { APP_MASTER_KEY = { secret = "secrets", key = "APP_MASTER_KEY" } }
    }
    # Deletes the sign-out revocations of expired refresh tokens.
    refresh-token-purge = {
      service    = "authentication"
      image      = "authentication/maintenance"
      schedule   = "40 3 * * *"
      suspend    = false
      args       = ["refresh-token-purge"]
      env        = {}
      secret_env = {}
    }
    # Deletes the expired authorization codes, after the refresh token purge.
    authorization-code-purge = {
      service    = "authentication"
      image      = "authentication/maintenance"
      schedule   = "50 3 * * *"
      suspend    = false
      args       = ["authorization-code-purge"]
      env        = {}
      secret_env = {}
    }
    # The maintenance template never runs on its own. The named operators' Jobs copy it and name
    # their operation in its arguments (maintenance.tf). Without one, the image prints its help.
    # account-role sends its mail within SMTP_TIMEOUT, and the deadline leaves room for the exit.
    maintenance = {
      service    = "authentication"
      image      = "authentication/maintenance"
      schedule   = "0 0 1 1 *"
      suspend    = true
      args       = []
      env        = local.authentication_mail_env
      secret_env = {}
    }
  }
}

resource "kubernetes_cron_job_v1" "scheduled" {
  for_each = var.custom_resources ? local.scheduled_jobs : {}

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.service[each.value.service].metadata[0].name
  }

  spec {
    schedule           = each.value.schedule
    suspend            = each.value.suspend
    timezone           = "Etc/UTC"
    concurrency_policy = "Forbid"

    job_template {
      metadata {}

      spec {
        backoff_limit           = 0
        active_deadline_seconds = 600

        # As the migrations' pods: the job reaches its database by the certificate's name.
        template {
          metadata {
            labels = merge(local.database_clients, { "app.kubernetes.io/name" = each.key })
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

            container {
              name  = each.key
              image = local.release_image[each.value.image]
              args  = each.value.args

              dynamic "env" {
                for_each = merge(local.database_env[each.value.service], local.downtime_env[each.value.service], each.value.env, local.telemetry_env[each.value.service].job, {
                  SSL_CERT_DIR = "/etc/ssl/certs:/etc/database-ca"
                })

                content {
                  name  = env.key
                  value = env.value
                }
              }

              dynamic "env" {
                for_each = merge(local.database_secret_env, each.value.secret_env)

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
                secret_name = kubernetes_manifest.database_server_certificate[each.value.service].manifest.spec.secretName

                items {
                  key  = "ca.crt"
                  path = "ca.crt"
                }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_job_v1.migrations, kubernetes_manifest.secrets]
}
