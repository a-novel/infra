locals {
  labels   = merge(var.labels, { "app.kubernetes.io/name" = var.name })
  protocol = var.http_health_path == null ? "grpc" : "http"
  # Go reads every directory SSL_CERT_DIR lists, beside the system bundle. Each service token sits in
  # a file named after its audience.
  env = merge(var.env, var.ca_secret == null ? {} : { SSL_CERT_DIR = "/etc/ssl/certs:/etc/database-ca" }, {
    for audience, name in var.service_tokens : name => "/var/run/secrets/tokens/${audience}"
  })
}

# The workload calls no Kubernetes API, so its pods mount no token for it.
resource "kubernetes_service_account_v1" "workload" {
  metadata {
    name      = var.name
    namespace = var.namespace
  }

  automount_service_account_token = false
}

resource "kubernetes_deployment_v1" "workload" {
  metadata {
    name      = var.name
    namespace = var.namespace
  }

  spec {
    replicas = var.replicas.min

    selector {
      match_labels = { "app.kubernetes.io/name" = var.name }
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        service_account_name            = kubernetes_service_account_v1.workload.metadata[0].name
        automount_service_account_token = false
        # Each Service in the namespace would otherwise inject <NAME>_PORT and the like, which our
        # services read as configuration: the grpc Service's GRPC_PORT crashed GenAI's sweep.
        enable_service_links = false

        # Our images start as root, so the pods name an unprivileged user, as Pod Security's
        # restricted level requires.
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # Pods spread across nodes, so a node's drain or loss stops at most one.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"

          label_selector {
            match_labels = { "app.kubernetes.io/name" = var.name }
          }
        }

        container {
          name  = var.name
          image = var.image

          port {
            name           = local.protocol
            container_port = var.port
          }

          dynamic "env" {
            for_each = local.env

            content {
              name  = env.key
              value = env.value
            }
          }

          dynamic "env" {
            for_each = var.secret_env

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

          dynamic "volume_mount" {
            for_each = var.ca_secret == null ? [] : ["database-ca"]

            content {
              name       = volume_mount.value
              mount_path = "/etc/database-ca"
              read_only  = true
            }
          }

          dynamic "volume_mount" {
            for_each = length(var.service_tokens) > 0 ? ["service-tokens"] : []

            content {
              name       = volume_mount.value
              mount_path = "/var/run/secrets/tokens"
              read_only  = true
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

          # A pod gets a minute to start, then serves only while its probe answers.
          startup_probe {
            period_seconds    = 2
            failure_threshold = 30

            dynamic "grpc" {
              for_each = local.protocol == "grpc" ? [var.port] : []

              content {
                port = grpc.value
              }
            }

            dynamic "http_get" {
              for_each = local.protocol == "http" ? [var.http_health_path] : []

              content {
                path = http_get.value
                port = var.port
              }
            }
          }

          readiness_probe {
            period_seconds = 5

            dynamic "grpc" {
              for_each = local.protocol == "grpc" ? [var.port] : []

              content {
                port = grpc.value
              }
            }

            dynamic "http_get" {
              for_each = local.protocol == "http" ? [var.http_health_path] : []

              content {
                path = http_get.value
                port = var.port
              }
            }
          }
        }

        # Only the CA's certificate: the Secret also holds the database's private key.
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

        # The kubelet renews each token before it expires.
        dynamic "volume" {
          for_each = length(var.service_tokens) > 0 ? ["service-tokens"] : []

          content {
            name = volume.value

            projected {
              dynamic "sources" {
                for_each = var.service_tokens

                content {
                  service_account_token {
                    audience = sources.key
                    path     = sources.key
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  # The autoscaler owns the count once it runs.
  lifecycle {
    ignore_changes = [spec[0].replicas]
  }
}

resource "kubernetes_service_v1" "workload" {
  metadata {
    name      = var.name
    namespace = var.namespace
  }

  spec {
    selector = { "app.kubernetes.io/name" = var.name }

    port {
      name        = local.protocol
      port        = var.port
      target_port = var.port
    }
  }
}

# A drain may stop all but one pod at a time. A single pod gets no budget, which would block drains.
resource "kubernetes_pod_disruption_budget_v1" "workload" {
  count = var.replicas.min > 1 ? 1 : 0

  metadata {
    name      = var.name
    namespace = var.namespace
  }

  spec {
    min_available = 1

    selector {
      match_labels = { "app.kubernetes.io/name" = var.name }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "workload" {
  count = var.replicas.max > var.replicas.min ? 1 : 0

  metadata {
    name      = var.name
    namespace = var.namespace
  }

  spec {
    min_replicas = var.replicas.min
    max_replicas = var.replicas.max

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.workload.metadata[0].name
    }

    metric {
      type = "Resource"

      resource {
        name = "cpu"

        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
}

output "pod_labels" {
  description = "The workload's pod labels, which network policies select."
  value       = local.labels
}

output "service" {
  description = "The workload's Service, as a route or a health check names it."
  value       = { name = kubernetes_service_v1.workload.metadata[0].name, port = var.port }
}

output "service_account" {
  description = "The workload's Kubernetes service account, as service tokens name it."
  value       = "system:serviceaccount:${var.namespace}:${kubernetes_service_account_v1.workload.metadata[0].name}"
}
