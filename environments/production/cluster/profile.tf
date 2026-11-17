# The profile service's REST API, which stores each user's username and picture. Every platform
# calls it server-side for its visitors, whose access tokens it verifies against JSON Keys.
locals {
  profile_env = merge(local.database_env["profile"], local.downtime_env["profile"], local.telemetry_env["profile"].api, {
    GOMEMLIMIT              = "400MiB"
    POSTGRES_MAX_OPEN_CONNS = "10"
    POSTGRES_MAX_IDLE_CONNS = "5"
    REST_PORT               = tostring(local.service_port)
    SERVICE_JSON_KEYS_HOST  = "grpc.json-keys.svc"
    SERVICE_JSON_KEYS_PORT  = local.json_keys_env.GRPC_PORT
    SERVICE_JSON_KEYS_TLS   = "true"
    SERVICE_TOKEN_ISSUER    = local.service_token_issuer
    SERVICE_TOKEN_AUDIENCE  = "profile"
    SERVICE_TOKEN_CALLERS   = local.token_callers["profile/rest"]
    # Only the platforms call the API for their visitors, so it can trust the visitor IP they
    # forward. Without it, every visitor would share their platform's rate limit.
    REST_CLIENT_IP_HEADER = "X-Client-IP"
  })
}

module "profile_rest" {
  source = "../../../modules/cluster-workload"
  lifecycle { enabled = var.custom_resources }

  name             = "rest"
  namespace        = kubernetes_namespace_v1.service["profile"].metadata[0].name
  image            = local.release_image["profile/rest"]
  port             = local.service_port
  tls              = { secret = kubernetes_manifest.service_server_certificate["profile/rest"].manifest.spec.secretName }
  service_ca       = kubernetes_manifest.service_trust_bundle.manifest.metadata.name
  http_health_path = "/v1/ping"
  env              = local.profile_env
  secret_env       = local.database_secret_env
  service_tokens   = { (local.json_keys_env.SERVICE_TOKEN_AUDIENCE) = "SERVICE_JSON_KEYS_TOKEN_PATH" }
  ca_secret        = kubernetes_manifest.database_server_certificate["profile"].manifest.spec.secretName
  resources        = { cpu = "100m", memory = "512Mi" }
  labels           = local.database_clients
  pod_annotations  = local.database_client_annotations

  # Two keep profiles up through a lost pod or node. A third, on CPU, follows the platforms' third,
  # since every platform calls it.
  replicas = { min = 2, max = 3 }

  depends_on = [kubernetes_job_v1.migrations]
}
