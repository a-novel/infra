# Each service API's health check: JSON Keys' and GenAI's Status RPC, and the health endpoints of
# Authentication, narrative-engine, profile and JSON Keys' public keys. A Job checks each new image,
# script or setting, and the deploy waits on it; a CronJob checks every five minutes, so a failing
# service shows as failed Jobs. Both call as the namespace's smoke identity, which each API admits, with the
# service token the kubelet projects for its audience, or none for a public API. A planned downtime
# skips the check, and clearing it runs the Job again.
locals {
  health_check_script = file("${path.module}/../../../modules/smoke-check/smoke.sh")
  # Each check runs in the image of the pods it checks, which carries grpcurl or BusyBox wget, and
  # verifies them against the services CA, which both read from SSL_CERT_FILE. A check takes its
  # service's name, and the check of a service's second API adds that API's workload.
  health_check_targets = {
    authentication   = { service = "authentication", pods = "rest", env = { PROTOCOL = "http", HEALTH_PATH = "/v2/healthcheck" } }
    genai            = { service = "genai", pods = "grpc", env = { PROTOCOL = "grpc", STATUS_RPC = "anovel.genai.v0.StatusService/Status" } }
    json-keys        = { service = "json-keys", pods = "grpc", env = { PROTOCOL = "grpc", STATUS_RPC = "anovel.jsonkeys.v2.StatusService/Status" } }
    json-keys-rest   = { service = "json-keys", pods = "rest", env = { PROTOCOL = "http", HEALTH_PATH = "/v2/healthcheck", PUBLIC = "true" } }
    narrative-engine = { service = "narrative-engine", pods = "rest", env = { PROTOCOL = "http", HEALTH_PATH = "/v1/healthcheck" } }
    profile          = { service = "profile", pods = "rest", env = { PROTOCOL = "http", HEALTH_PATH = "/v1/healthcheck" } }
  }
  # A check sends the token of its API's audience, its namespace, unless the API takes none (apis.tf).
  health_checks = { for name, target in local.health_check_targets : name => merge(target, {
    audience = local.apis["${target.service}/${target.pods}"].tokens ? target.service : null
    image    = "${target.service}/${target.pods}"
    cron_job = name == target.service ? "health" : "health-${target.pods}"
    env = merge(target.env, local.downtime_env[target.service], {
      SERVICE_URL   = "https://${target.pods}.${target.service}.svc:${local.service_port}"
      SSL_CERT_FILE = "/etc/service-ca/ca.crt"
    }, local.apis["${target.service}/${target.pods}"].tokens ? { SERVICE_TOKEN_PATH = "/var/run/secrets/tokens/${target.service}" } : {})
  }) }
  # Each namespace's checks share its smoke identity and policy.
  health_check_namespaces = toset([for check in values(local.health_checks) : check.service])
}

# The check calls no Kubernetes API, so its pods mount no token for it.
resource "kubernetes_service_account_v1" "smoke" {
  for_each = local.health_check_namespaces

  metadata {
    name      = "smoke"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  automount_service_account_token = false
}

# The checks reach only the pods they check. Their own policies admit them.
resource "kubernetes_network_policy_v1" "smoke" {
  for_each = local.health_check_namespaces

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
      dynamic "to" {
        for_each = [for check in values(local.health_checks) : check.pods if check.service == each.key]

        content {
          pod_selector {
            match_labels = { "app.kubernetes.io/name" = to.value }
          }
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
module "smoke" {
  source   = "../../../modules/cluster-job"
  for_each = var.custom_resources ? local.health_checks : {}

  name            = "smoke-${substr(sha256(jsonencode([local.release_image[each.value.image], each.value.env, local.health_check_script])), 0, 12)}"
  namespace       = kubernetes_namespace_v1.service[each.value.service].metadata[0].name
  labels          = { "app.kubernetes.io/name" = "smoke" }
  service_account = kubernetes_service_account_v1.smoke[each.value.service].metadata[0].name

  container_name = "smoke"
  image          = local.release_image[each.value.image]
  command        = ["/bin/sh"]
  args           = ["-c", local.health_check_script]
  env            = each.value.env
  service_token  = each.value.audience
  service_ca     = kubernetes_manifest.service_trust_bundle.manifest.metadata.name
  # The script keeps the service's answer here.
  tmp_size  = "1Mi"
  resources = { cpu = "50m", memory = "64Mi" }

  active_deadline_seconds = 300
  timeout                 = "6m"

  # Each check needs its service rolled out and reachable, Authentication's mail relay included.
  depends_on = [module.authentication_rest, module.genai_grpc, module.json_keys_grpc, module.json_keys_rest, module.narrative_engine_rest, module.profile_rest, kubernetes_network_policy_v1.smoke, kubernetes_manifest.internet_egress]
}

# The CronJob runs the same check on a schedule, as health, or health-<workload> for a service's
# second API. The script retries for two minutes, so a failed run means the service failed for that
# long.
module "health" {
  source   = "../../../modules/cluster-job"
  for_each = var.custom_resources ? local.health_checks : {}

  name      = each.value.cron_job
  namespace = kubernetes_namespace_v1.service[each.value.service].metadata[0].name
  schedule  = "*/5 * * * *"

  # As the smoke Job's pods.
  labels          = { "app.kubernetes.io/name" = "smoke" }
  service_account = kubernetes_service_account_v1.smoke[each.value.service].metadata[0].name

  container_name = "health"
  image          = local.release_image[each.value.image]
  command        = ["/bin/sh"]
  args           = ["-c", local.health_check_script]
  env            = each.value.env
  service_token  = each.value.audience
  service_ca     = kubernetes_manifest.service_trust_bundle.manifest.metadata.name
  tmp_size       = "1Mi"
  resources      = { cpu = "50m", memory = "64Mi" }

  active_deadline_seconds = 300

  depends_on = [module.smoke]
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

# The cluster-job module's Jobs plan every change to their spec, and a lifecycle argument cannot vary
# per caller, so this Job writes its own pods.
resource "kubernetes_job_v1" "provider_check" {
  # Only a new revision runs the check again: a new image, setting or downtime leaves the finished Job
  # alone. A failed Job stays tainted, so the next deploy runs it again.
  lifecycle {
    enabled        = var.custom_resources && var.genai_provider_check != null
    ignore_changes = [spec]
  }

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
            name = kubernetes_manifest.service_trust_bundle.manifest.metadata.name

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

  # The call needs GenAI's server rolled out and its way to OpenAI.
  depends_on = [module.genai_grpc, kubernetes_network_policy_v1.smoke, kubernetes_manifest.internet_egress]
}
