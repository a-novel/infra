locals {
  # Each mount reads the volume of the same name, which the pod declares only with its mount.
  mounts = concat(
    var.ca_secret == null ? [] : [{ name = "database-ca", path = "/etc/database-ca", read_only = true }],
    var.service_token == null ? [] : [{ name = "service-token", path = "/var/run/secrets/tokens", read_only = true }],
    var.service_ca == null ? [] : [{ name = "service-ca", path = "/etc/service-ca", read_only = true }],
    var.tmp_size == null ? [] : [{ name = "tmp", path = "/tmp", read_only = null }],
  )
}

# One run, which the apply waits on. A finished Job stays as its record. A failed one fails the apply
# and stays tainted, so the next apply runs it again.
resource "kubernetes_job_v1" "job" {
  lifecycle { enabled = var.schedule == null }

  metadata {
    name      = var.name
    namespace = var.namespace
  }

  spec {
    backoff_limit           = 0
    active_deadline_seconds = var.active_deadline_seconds

    template {
      metadata {
        labels = var.labels
      }

      spec {
        restart_policy                  = "Never"
        service_account_name            = var.service_account
        automount_service_account_token = false
        # Each Service in the namespace would otherwise inject <NAME>_PORT and the like, which our
        # programs read as configuration.
        enable_service_links = false

        # Images start as root, so the pods name an unprivileged user, as Pod Security's restricted
        # level requires.
        security_context {
          run_as_non_root = true
          run_as_user     = var.user
          run_as_group    = var.user

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = var.container_name
          image   = var.image
          command = var.command
          args    = var.args

          dynamic "env" {
            for_each = var.env

            content {
              name  = env.key
              value = env.value
            }
          }

          dynamic "env" {
            for_each = var.secret_env

            content {
              name = env.value.name

              value_from {
                secret_key_ref {
                  name = env.value.secret
                  key  = env.value.key
                }
              }
            }
          }

          dynamic "volume_mount" {
            for_each = local.mounts

            content {
              name       = volume_mount.value.name
              mount_path = volume_mount.value.path
              read_only  = volume_mount.value.read_only
            }
          }

          resources {
            requests = { cpu = var.resources.cpu, memory = var.resources.memory }
            limits   = { memory = var.resources.memory }
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

        # Only the CA's certificate: the Secret also holds a private key.
        dynamic "volume" {
          for_each = var.ca_secret == null ? [] : [var.ca_secret]

          content {
            name = "database-ca"

            secret {
              secret_name = volume.value

              items {
                key  = "ca.crt"
                path = "ca.crt"
              }
            }
          }
        }

        dynamic "volume" {
          for_each = var.service_token == null ? [] : [var.service_token]

          content {
            name = "service-token"

            projected {
              sources {
                service_account_token {
                  audience = volume.value
                  path     = volume.value
                }
              }
            }
          }
        }

        # Only the CA's certificate, which trust-manager keeps current.
        dynamic "volume" {
          for_each = var.service_ca == null ? [] : [var.service_ca]

          content {
            name = "service-ca"

            config_map {
              name = volume.value

              items {
                key  = "ca.crt"
                path = "ca.crt"
              }
            }
          }
        }

        dynamic "volume" {
          for_each = var.tmp_size == null ? [] : [var.tmp_size]

          content {
            name = "tmp"

            empty_dir {
              medium     = "Memory"
              size_limit = volume.value
            }
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = var.timeout
  }
}

# Each run starts on the schedule, one at a time, and a failed one is never retried: the next run
# takes over. Its pods are the Job's above.
resource "kubernetes_cron_job_v1" "cron_job" {
  lifecycle { enabled = var.schedule != null }

  metadata {
    name      = var.name
    namespace = var.namespace
  }

  spec {
    schedule           = var.schedule
    suspend            = var.suspend
    timezone           = "Etc/UTC"
    concurrency_policy = "Forbid"

    # Kubernetes keeps the last failed run, and the CronJob the last successful one. Each kept run
    # holds its pod and that pod's logs.
    successful_jobs_history_limit = 1

    job_template {
      metadata {}

      spec {
        backoff_limit           = 0
        active_deadline_seconds = var.active_deadline_seconds

        template {
          metadata {
            labels = var.labels
          }

          spec {
            restart_policy                  = "Never"
            service_account_name            = var.service_account
            automount_service_account_token = false
            enable_service_links            = false

            security_context {
              run_as_non_root = true
              run_as_user     = var.user
              run_as_group    = var.user

              seccomp_profile {
                type = "RuntimeDefault"
              }
            }

            container {
              name    = var.container_name
              image   = var.image
              command = var.command
              args    = var.args

              dynamic "env" {
                for_each = var.env

                content {
                  name  = env.key
                  value = env.value
                }
              }

              dynamic "env" {
                for_each = var.secret_env

                content {
                  name = env.value.name

                  value_from {
                    secret_key_ref {
                      name = env.value.secret
                      key  = env.value.key
                    }
                  }
                }
              }

              dynamic "volume_mount" {
                for_each = local.mounts

                content {
                  name       = volume_mount.value.name
                  mount_path = volume_mount.value.path
                  read_only  = volume_mount.value.read_only
                }
              }

              resources {
                requests = { cpu = var.resources.cpu, memory = var.resources.memory }
                limits   = { memory = var.resources.memory }
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

            dynamic "volume" {
              for_each = var.ca_secret == null ? [] : [var.ca_secret]

              content {
                name = "database-ca"

                secret {
                  secret_name = volume.value

                  items {
                    key  = "ca.crt"
                    path = "ca.crt"
                  }
                }
              }
            }

            dynamic "volume" {
              for_each = var.service_token == null ? [] : [var.service_token]

              content {
                name = "service-token"

                projected {
                  sources {
                    service_account_token {
                      audience = volume.value
                      path     = volume.value
                    }
                  }
                }
              }
            }

            dynamic "volume" {
              for_each = var.service_ca == null ? [] : [var.service_ca]

              content {
                name = "service-ca"

                config_map {
                  name = volume.value

                  items {
                    key  = "ca.crt"
                    path = "ca.crt"
                  }
                }
              }
            }

            dynamic "volume" {
              for_each = var.tmp_size == null ? [] : [var.tmp_size]

              content {
                name = "tmp"

                empty_dir {
                  medium     = "Memory"
                  size_limit = volume.value
                }
              }
            }
          }
        }
      }
    }
  }
}

output "job" {
  description = "The Job as planned, or null for a CronJob. Callers read its name, and tests its fields."
  value       = kubernetes_job_v1.job
}

output "cron_job" {
  description = "The CronJob as planned, or null for a Job. Tests read its fields."
  value       = kubernetes_cron_job_v1.cron_job
}
