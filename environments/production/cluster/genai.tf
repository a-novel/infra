# GenAI's gRPC server, which scales on CPU and its calls in flight, and its sweep, which checks the
# generations nobody polled. Nothing calls the sweep, which reaches only OpenAI (egress.tf) and its
# database.
locals {
  genai_env        = merge(local.database_env["genai"], local.downtime_env["genai"])
  genai_secret_env = merge(local.database_secret_env, { OPENAI_API_KEY = { secret = "secrets", key = "OPENAI_API_KEY" } })

  genai_grpc_env = merge(local.genai_env, local.telemetry_env["genai"].api, {
    # 20 concurrent maximum-size submits peak at 1,575 MiB under this limit, and the server refuses
    # a call beyond them.
    GOMEMLIMIT                = "1600MiB"
    GRPC_MAX_CONCURRENT_CALLS = "20"
    GRPC_PORT                 = tostring(local.service_port)
    METRICS_PORT              = tostring(local.apis["genai/grpc"].metrics_port)
    POSTGRES_MAX_OPEN_CONNS   = "10"
    POSTGRES_MAX_IDLE_CONNS   = "10"
    SERVICE_TOKEN_ISSUER      = local.service_token_issuer
    SERVICE_TOKEN_AUDIENCE    = "genai"
    SERVICE_TOKEN_CALLERS     = local.token_callers["genai/grpc"]
  })

  genai_sweep_env = merge(local.genai_env, local.telemetry_env["genai"].job, {
    # A sweep only reads generations it checks, never their payloads, and keeps one of its 4
    # connections for its leader lock: 3 checks fit 1 GiB.
    GOMEMLIMIT              = "800MiB"
    POSTGRES_MAX_OPEN_CONNS = "4"
    POSTGRES_MAX_IDLE_CONNS = "4"
    REST_PORT               = "8080"
  })
}

module "genai_grpc" {
  source = "../../../modules/cluster-workload"
  lifecycle { enabled = var.custom_resources }

  name            = "grpc"
  namespace       = kubernetes_namespace_v1.service["genai"].metadata[0].name
  image           = local.release_image["genai/grpc"]
  port            = local.service_port
  tls             = { secret = kubernetes_manifest.service_server_certificate["genai/grpc"].manifest.spec.secretName }
  env             = local.genai_grpc_env
  secret_env      = local.genai_secret_env
  ca_secret       = kubernetes_manifest.database_server_certificate["genai"].manifest.spec.secretName
  resources       = { cpu = "100m", memory = "2Gi" }
  labels          = local.database_clients
  pod_annotations = local.database_client_annotations

  # Full pods wait on OpenAI and use little CPU, so the server also keeps its calls in flight at 60%
  # of its cap per pod.
  scaling_gauge = {
    name    = "grpc_server_calls_in_flight"
    port    = tonumber(local.genai_grpc_env.METRICS_PORT)
    average = floor(tonumber(local.genai_grpc_env.GRPC_MAX_CONCURRENT_CALLS) * 60 / 100)
  }
  # Two keep generations up through a lost pod or node. The autoscaler absorbs bursts only.
  # replicas.max times GRPC_MAX_CONCURRENT_CALLS bounds the calls the server runs at once, and so the
  # requests it sends OpenAI: a hard bound on spend and load.
  replicas = { min = 2, max = 3 }

  depends_on = [module.migrations, kubernetes_manifest.secrets]
}

module "genai_sweep" {
  source = "../../../modules/cluster-workload"
  lifecycle { enabled = var.custom_resources }

  name             = "sweep"
  namespace        = kubernetes_namespace_v1.service["genai"].metadata[0].name
  image            = local.release_image["genai/sweep"]
  port             = 8080
  http_health_path = "/ping"
  env              = local.genai_sweep_env
  secret_env       = local.genai_secret_env
  ca_secret        = kubernetes_manifest.database_server_certificate["genai"].manifest.spec.secretName
  resources        = { cpu = "100m", memory = "1Gi" }
  labels           = local.database_clients
  pod_annotations  = local.database_client_annotations

  # One replica sweeps at a time, under a leader lock. A second stands by and takes the lock when the
  # leader's pod or node is lost.
  replicas = { min = 2, max = 3 }

  depends_on = [module.migrations, kubernetes_manifest.secrets]
}
