# Each service's health check, which Cloud Run's smoke jobs and health action run too: JSON Keys'
# and GenAI's Status RPC, and Authentication's health endpoint. A Job checks each new image, script
# or setting, and the deploy waits on it; a CronJob checks every five minutes, so a failing service
# shows as failed Jobs. Both call as the namespace's smoke identity, which each service admits,
# with the service token the kubelet projects for its audience. A planned downtime skips the check,
# and clearing it runs the Job again.
locals {
  health_check_script = file("${path.module}/../../../modules/smoke-check/smoke.sh")
  # Each check runs in its service's own image, which carries grpcurl or BusyBox wget.
  health_check_targets = {
    authentication = { image = "authentication/rest", pods = "rest", port = local.authentication_env.REST_PORT, audience = local.authentication_env.SERVICE_TOKEN_AUDIENCE, env = { PROTOCOL = "http", HEALTH_PATH = "/v2/healthcheck" } }
    genai          = { image = "genai/grpc", pods = "grpc", port = local.genai_grpc_env.GRPC_PORT, audience = local.genai_grpc_env.SERVICE_TOKEN_AUDIENCE, env = { PROTOCOL = "grpc", STATUS_RPC = "anovel.genai.v0.StatusService/Status" } }
    json-keys      = { image = "json-keys/grpc", pods = "grpc", port = local.json_keys_env.GRPC_PORT, audience = local.json_keys_env.SERVICE_TOKEN_AUDIENCE, env = { PROTOCOL = "grpc", STATUS_RPC = "anovel.jsonkeys.v2.StatusService/Status" } }
  }
  health_checks = { for service, target in local.health_check_targets : service => merge(target, {
    env = merge(target.env, local.downtime_env[service], {
      SERVICE_URL        = "http://${target.pods}.${service}.svc:${target.port}"
      SERVICE_TOKEN_PATH = "/var/run/secrets/tokens/${target.audience}"
    })
  }) }
}

# The check calls no Kubernetes API, so its pods mount no token for it.
resource "kubernetes_service_account_v1" "smoke" {
  for_each = local.health_checks

  metadata {
    name      = "smoke"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  automount_service_account_token = false
}

# The check reaches only the pods it checks. Their own policies admit it.
resource "kubernetes_network_policy_v1" "smoke" {
  for_each = local.health_checks

  metadata {
    name      = "smoke"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "smoke" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = each.value.pods }
        }
      }

      ports {
        port     = each.value.port
        protocol = "TCP"
      }
    }
  }
}

# The Job's name follows everything its pod runs, so a new image, script or setting runs it once. A
# finished Job stays as its record, and a failed one fails the deploy.
resource "kubernetes_job_v1" "smoke" {
  for_each = var.custom_resources ? local.health_checks : {}

  metadata {
    name      = "smoke-${substr(sha256(jsonencode([local.release_image[each.value.image], each.value.env, local.health_check_script])), 0, 12)}"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  spec {
    backoff_limit           = 0
    active_deadline_seconds = 300

    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "smoke" }
      }

      spec {
        restart_policy                  = "Never"
        service_account_name            = kubernetes_service_account_v1.smoke[each.key].metadata[0].name
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
          name    = "smoke"
          image   = local.release_image[each.value.image]
          command = ["/bin/sh"]
          args    = ["-c", local.health_check_script]

          dynamic "env" {
            for_each = each.value.env

            content {
              name  = env.key
              value = env.value
            }
          }

          volume_mount {
            name       = "service-token"
            mount_path = "/var/run/secrets/tokens"
            read_only  = true
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
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
          name = "service-token"

          projected {
            sources {
              service_account_token {
                audience = each.value.audience
                path     = each.value.audience
              }
            }
          }
        }

        # The script keeps the service's answer here.
        volume {
          name = "tmp"

          empty_dir {
            medium     = "Memory"
            size_limit = "1Mi"
          }
        }
      }
    }
  }

  wait_for_completion = true

  timeouts {
    create = "6m"
  }

  # Each check needs its service rolled out and reachable, Authentication's mail relay included.
  depends_on = [module.authentication_rest, module.genai_grpc, module.json_keys_grpc, kubernetes_network_policy_v1.smoke, kubernetes_manifest.internet_egress]
}

# The CronJob runs the same check on a schedule. The script retries for two minutes, so a failed run
# means the service failed for that long.
resource "kubernetes_cron_job_v1" "health" {
  for_each = var.custom_resources ? local.health_checks : {}

  metadata {
    name      = "health"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  spec {
    schedule           = "*/5 * * * *"
    timezone           = "Etc/UTC"
    concurrency_policy = "Forbid"

    job_template {
      metadata {}

      spec {
        backoff_limit           = 0
        active_deadline_seconds = 300

        # As the smoke Job's pods.
        template {
          metadata {
            labels = { "app.kubernetes.io/name" = "smoke" }
          }

          spec {
            restart_policy                  = "Never"
            service_account_name            = kubernetes_service_account_v1.smoke[each.key].metadata[0].name
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
              name    = "health"
              image   = local.release_image[each.value.image]
              command = ["/bin/sh"]
              args    = ["-c", local.health_check_script]

              dynamic "env" {
                for_each = each.value.env

                content {
                  name  = env.key
                  value = env.value
                }
              }

              volume_mount {
                name       = "service-token"
                mount_path = "/var/run/secrets/tokens"
                read_only  = true
              }

              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
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
              name = "service-token"

              projected {
                sources {
                  service_account_token {
                    audience = each.value.audience
                    path     = each.value.audience
                  }
                }
              }
            }

            volume {
              name = "tmp"

              empty_dir {
                medium     = "Memory"
                size_limit = "1Mi"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubernetes_job_v1.smoke]
}
