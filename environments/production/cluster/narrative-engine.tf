# Narrative-engine's REST API, which stores each project's Scenes Composer and runs its AI suggestions
# through GenAI. Only its smoke check calls it until Studio does (a-novel/.github#542). Its streams
# and generation submits stay inside the cluster, so no load balancer times them.
locals {
  narrative_engine_env = merge(local.database_env["narrative-engine"], local.downtime_env["narrative-engine"], local.telemetry_env["narrative-engine"].api, {
    # A read of a whole project takes up to 128 MiB, and the reads together half of this limit: one
    # read at a time per pod, the others waiting for it.
    GOMEMLIMIT              = "400MiB"
    POSTGRES_MAX_OPEN_CONNS = "10"
    POSTGRES_MAX_IDLE_CONNS = "5"
    REST_PORT               = tostring(local.service_port)
    SERVICE_JSON_KEYS_HOST  = "grpc.json-keys.svc"
    SERVICE_JSON_KEYS_PORT  = local.json_keys_env.GRPC_PORT
    SERVICE_JSON_KEYS_TLS   = "true"
    SERVICE_GENAI_HOST      = "grpc.genai.svc"
    SERVICE_GENAI_PORT      = local.genai_grpc_env.GRPC_PORT
    SERVICE_GENAI_TLS       = "true"
    SERVICE_TOKEN_ISSUER    = local.service_token_issuer
    SERVICE_TOKEN_AUDIENCE  = "narrative-engine"
    SERVICE_TOKEN_CALLERS   = "system:serviceaccount:narrative-engine:smoke"
  })
}

module "narrative_engine_rest" {
  source = "../../../modules/cluster-workload"
  count  = var.custom_resources ? 1 : 0

  name             = "rest"
  namespace        = kubernetes_namespace_v1.service["narrative-engine"].metadata[0].name
  image            = local.release_image["narrative-engine/rest"]
  port             = local.service_port
  tls              = { secret = kubernetes_manifest.service_server_certificate["narrative-engine/rest"].manifest.spec.secretName }
  service_ca       = kubernetes_manifest.service_trust_bundle[0].manifest.metadata.name
  http_health_path = "/v1/ping"
  env              = local.narrative_engine_env
  secret_env       = local.database_secret_env
  service_tokens = {
    (local.json_keys_env.SERVICE_TOKEN_AUDIENCE)  = "SERVICE_JSON_KEYS_TOKEN_PATH"
    (local.genai_grpc_env.SERVICE_TOKEN_AUDIENCE) = "SERVICE_GENAI_TOKEN_PATH"
  }
  ca_secret       = kubernetes_manifest.database_server_certificate["narrative-engine"].manifest.spec.secretName
  resources       = { cpu = "100m", memory = "512Mi" }
  labels          = local.database_clients
  pod_annotations = local.database_client_annotations

  # Two keep the Composer up through a lost pod or node. A third, on CPU, absorbs bursts of project
  # reads.
  replicas = { min = 2, max = 3 }

  depends_on = [kubernetes_job_v1.migrations]
}

# Only the smoke check calls the API, which calls JSON Keys and GenAI, and reaches the issuer's keys
# through Google's restricted API addresses.
resource "kubernetes_network_policy_v1" "narrative_engine_rest" {
  metadata {
    name      = "rest"
    namespace = kubernetes_namespace_v1.service["narrative-engine"].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "rest" }
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "smoke" }
        }
      }

      ports {
        port     = tostring(local.service_port)
        protocol = "TCP"
      }
    }

    egress {
      dynamic "to" {
        for_each = ["json-keys", "genai"]

        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = to.value }
          }
          pod_selector {
            match_labels = { "app.kubernetes.io/name" = "grpc" }
          }
        }
      }

      ports {
        port     = tostring(local.service_port)
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
