# Each service's health check: JSON Keys' and GenAI's Status RPC, and Authentication's health
# endpoint. A Job checks each new image, script or setting, and the deploy waits on it; a CronJob
# checks every five minutes, so a failing service shows as failed Jobs. Both call as the namespace's
# smoke identity, which each service admits, with the service token the kubelet projects for its
# audience. A planned downtime skips the check, and clearing it runs the Job again.
locals {
  health_check_script = file("${path.module}/../../../modules/smoke-check/smoke.sh")
  # Each check runs in its service's own image, which carries grpcurl or BusyBox wget, and verifies
  # its service against the services CA, which both read from SSL_CERT_FILE.
  health_check_targets = {
    authentication = { image = "authentication/rest", pods = "rest", audience = local.authentication_env.SERVICE_TOKEN_AUDIENCE, env = { PROTOCOL = "http", HEALTH_PATH = "/v2/healthcheck" } }
    genai          = { image = "genai/grpc", pods = "grpc", audience = local.genai_grpc_env.SERVICE_TOKEN_AUDIENCE, env = { PROTOCOL = "grpc", STATUS_RPC = "anovel.genai.v0.StatusService/Status" } }
    json-keys      = { image = "json-keys/grpc", pods = "grpc", audience = local.json_keys_env.SERVICE_TOKEN_AUDIENCE, env = { PROTOCOL = "grpc", STATUS_RPC = "anovel.jsonkeys.v2.StatusService/Status" } }
  }
  health_checks = { for service, target in local.health_check_targets : service => merge(target, {
    env = merge(target.env, local.downtime_env[service], {
      SERVICE_URL        = "https://${target.pods}.${service}.svc:${local.service_port}"
      SSL_CERT_FILE      = "/etc/service-ca/ca.crt"
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
        port     = tostring(local.service_port)
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
            name       = "service-ca"
            mount_path = "/etc/service-ca"
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

        # Only the CA's certificate, which trust-manager keeps current.
        volume {
          name = "service-ca"

          config_map {
            name = kubernetes_manifest.service_trust_bundle[0].manifest.metadata.name

            items {
              key  = "ca.crt"
              path = "ca.crt"
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
                name       = "service-ca"
                mount_path = "/etc/service-ca"
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

            # Only the CA's certificate, which trust-manager keeps current.
            volume {
              name = "service-ca"

              config_map {
                name = kubernetes_manifest.service_trust_bundle[0].manifest.metadata.name

                items {
                  key  = "ca.crt"
                  path = "ca.crt"
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

# GenAI's provider check makes one real OpenAI call, as GenAI's smoke identity. It runs once for each
# revision genai_provider_check names, and the deploy waits on it. A planned downtime skips it.
locals {
  provider_check_script = file("${path.module}/provider-check.sh")
  provider_check_env = var.genai_provider_check == null ? null : merge(local.downtime_env["genai"], {
    SERVICE_URL        = local.health_checks["genai"].env.SERVICE_URL
    SERVICE_TOKEN_PATH = local.health_checks["genai"].env.SERVICE_TOKEN_PATH
    SSL_CERT_FILE      = local.health_checks["genai"].env.SSL_CERT_FILE
    SUBMIT_REQUEST = jsonencode({
      # Each revision acts for its own user, whom no account holds, so it makes a new call under its
      # own caps. GenAI answers a resent request with the generation it already ran.
      owner_id = uuidv5("a0d26c4d-19c1-49c9-9b2d-49f52d36671a", var.genai_provider_check)
      # GenAI refuses a purpose its caps do not declare.
      purpose  = "studio.generation"
      provider = "openai"
      # A tiny call: the small gpt-5.6-luna at low effort, cut at the 16 output tokens the Responses
      # API allows at least. GenAI settles a cut answer as a success. gRPC's JSON form of bytes is
      # base64.
      payload = base64encode(jsonencode({
        model             = "gpt-5.6-luna"
        reasoning         = { effort = "low" }
        max_output_tokens = 16
        store             = false
        input             = "Reply with OK."
      }))
    })
  })
}

resource "kubernetes_job_v1" "provider_check" {
  count = var.custom_resources && var.genai_provider_check != null ? 1 : 0

  metadata {
    name      = "provider-check-${var.genai_provider_check}"
    namespace = kubernetes_namespace_v1.service["genai"].metadata[0].name
  }

  spec {
    backoff_limit           = 0
    active_deadline_seconds = 540

    # As the smoke Job's pods, which GenAI's server admits.
    template {
      metadata {
        labels = { "app.kubernetes.io/name" = "smoke" }
      }

      spec {
        restart_policy                  = "Never"
        service_account_name            = kubernetes_service_account_v1.smoke["genai"].metadata[0].name
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
          name    = "provider-check"
          image   = local.release_image["genai/grpc"]
          command = ["/bin/sh"]
          args    = ["-c", local.provider_check_script]

          dynamic "env" {
            for_each = local.provider_check_env

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
            name       = "service-ca"
            mount_path = "/etc/service-ca"
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
          name = "service-token"

          projected {
            sources {
              service_account_token {
                audience = local.health_checks["genai"].audience
                path     = local.health_checks["genai"].audience
              }
            }
          }
        }

        # Only the CA's certificate, which trust-manager keeps current.
        volume {
          name = "service-ca"

          config_map {
            name = kubernetes_manifest.service_trust_bundle[0].manifest.metadata.name

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

  # Only a new revision runs the check again: a new image, setting or downtime leaves the finished Job
  # alone. A failed Job stays tainted, so the next deploy runs it again.
  lifecycle {
    ignore_changes = [spec]
  }

  # The call needs GenAI's server rolled out and its way to OpenAI.
  depends_on = [module.genai_grpc, kubernetes_network_policy_v1.smoke, kubernetes_manifest.internet_egress]
}
