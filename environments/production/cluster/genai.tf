# GenAI on the cluster, which serves no one until the cutover (a-novel/.github#522): its gRPC server,
# which scales on CPU, and the sweep, which checks the generations nobody polled. Both reach OpenAI
# once a-novel/infra#1200 opens the way.
locals {
  genai_env = merge(local.database_env["genai"], local.downtime_env["genai"], {
    # Alloy carries the telemetry once it runs (a-novel/infra#1206).
    OTEL = "false"
  })
  genai_secret_env = merge(local.database_secret_env, { OPENAI_API_KEY = { secret = "secrets", key = "OPENAI_API_KEY" } })

  genai_grpc_env = merge(local.genai_env, {
    # Polls stop reaching the provider more than once per interval, which also bounds the reads in
    # flight while the provider is slow.
    CHECK_INTERVAL = "10s"
    # 20 concurrent maximum-size submits peak at 1,575 MiB under this limit, and the server refuses
    # a call beyond them.
    GOMEMLIMIT                = "1600MiB"
    GRPC_MAX_CONCURRENT_CALLS = "20"
    GRPC_PORT                 = "8080"
    POSTGRES_MAX_OPEN_CONNS   = "10"
    POSTGRES_MAX_IDLE_CONNS   = "10"
    SERVICE_TOKEN_ISSUER      = local.service_token_issuer
    SERVICE_TOKEN_AUDIENCE    = "genai"
    SERVICE_TOKEN_CALLERS     = "system:serviceaccount:genai:smoke"
  })

  genai_sweep_env = merge(local.genai_env, {
    # A sweep starts pending generations, which reads their payloads: 4 checks fit 1 GiB.
    GOMEMLIMIT              = "800MiB"
    POSTGRES_MAX_OPEN_CONNS = "4"
    POSTGRES_MAX_IDLE_CONNS = "4"
    REST_PORT               = "8080"
    # The sweep runs itself every SWEEP_INTERVAL, a minute by default, instead of waiting for a call.
    SWEEP_TICKER = "true"
  })
}

module "genai_grpc" {
  source = "../../../modules/cluster-workload"
  count  = var.custom_resources ? 1 : 0

  name       = "grpc"
  namespace  = kubernetes_namespace_v1.service["genai"].metadata[0].name
  image      = local.release_image["genai/grpc"]
  port       = 8080
  env        = local.genai_grpc_env
  secret_env = local.genai_secret_env
  ca_secret  = kubernetes_manifest.database_server_certificate["genai"].manifest.spec.secretName
  resources  = { cpu = "250m", memory = "2Gi" }
  replicas   = { min = 1, max = 4 }
  labels     = local.database_clients

  depends_on = [kubernetes_job_v1.migrations, kubernetes_manifest.secrets]
}

module "genai_sweep" {
  source = "../../../modules/cluster-workload"
  count  = var.custom_resources ? 1 : 0

  name             = "sweep"
  namespace        = kubernetes_namespace_v1.service["genai"].metadata[0].name
  image            = local.release_image["genai/sweep"]
  port             = 8080
  http_health_path = "/ping"
  env              = local.genai_sweep_env
  secret_env       = local.genai_secret_env
  ca_secret        = kubernetes_manifest.database_server_certificate["genai"].manifest.spec.secretName
  resources        = { cpu = "100m", memory = "1Gi" }
  replicas         = { min = 1, max = 1 }
  labels           = local.database_clients

  depends_on = [kubernetes_job_v1.migrations, kubernetes_manifest.secrets]
}

# Only GenAI's smoke check calls the server, which reaches the issuer's keys through Google's
# restricted API addresses. Nothing calls the sweep, so the namespace's default policy covers it.
resource "kubernetes_network_policy_v1" "genai_grpc" {
  metadata {
    name      = "grpc"
    namespace = kubernetes_namespace_v1.service["genai"].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "grpc" }
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "smoke" }
        }
      }

      ports {
        port     = local.genai_grpc_env.GRPC_PORT
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
