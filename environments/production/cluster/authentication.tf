# Authentication's REST API. Its pods share each rate limit's budget through the counter store
# (counter-store.tf). golib's router limit (REST_RATE_LIMIT) stays in each pod and grows with their
# count: it guards against floods, while the shared limits guard sign-in.
locals {
  authentication_smtp = local.service_inputs["authentication"].smtp
  # Registration and account emails, which the API and the maintenance Jobs send, and whose links
  # open the account platform on its own host. The relay admits them by the NAT address, so they
  # carry no SMTP credential. RFC 5321 gives each SMTP command minutes, and no request waits for a
  # send.
  authentication_mail_env = {
    PLATFORM_AUTH_URL   = "https://${local.platform_edges.account.host}"
    SMTP_ADDR           = "${local.authentication_smtp.host}:587"
    SMTP_MAX_CONCURRENT = "8"
    SMTP_SENDER_EMAIL   = local.authentication_smtp.sender_email
    SMTP_SENDER_NAME    = local.authentication_smtp.sender_name
    SMTP_TIMEOUT        = "300s"
  }
  authentication_env = merge(local.database_env["authentication"], local.downtime_env["authentication"], local.authentication_mail_env, local.telemetry_env["authentication"].api, {
    # One 64 MiB Argon2 hash at a time: more slots add memory, not throughput.
    ARGON2_MAX_CONCURRENT = "1"
    # The Go runtime does not read the container's memory limit; this lets it reclaim one hash's
    # 64 MiB before the next one doubles the heap.
    GOMEMLIMIT              = "384MiB"
    POSTGRES_MAX_OPEN_CONNS = "10"
    POSTGRES_MAX_IDLE_CONNS = "5"
    # Only the platforms call the API for their visitors, so it can trust the visitor IP they
    # forward.
    REST_CLIENT_IP_HEADER  = "X-Client-IP"
    REST_PORT              = tostring(local.service_port)
    SERVICE_JSON_KEYS_HOST = "grpc.json-keys.svc"
    SERVICE_JSON_KEYS_PORT = local.json_keys_env.GRPC_PORT
    SERVICE_JSON_KEYS_TLS  = "true"
    SERVICE_TOKEN_ISSUER   = local.service_token_issuer
    SERVICE_TOKEN_AUDIENCE = "authentication"
    SERVICE_TOKEN_CALLERS  = join(",", concat(values(local.platform_callers), ["system:serviceaccount:authentication:smoke"]))
    # Every pod counts its rate limits in the counter store as its limiter user, and on its own
    # while the store does not answer.
    REST_RATE_LIMIT_STORE_ADDR     = "valkey.authentication.svc:6379"
    REST_RATE_LIMIT_STORE_USERNAME = "limiter"
    # The invitation list that "Register" joins: an Apps Script web app, which accepts only requests
    # signed with WAITLIST_SECRET. Without it, every join fails.
    WAITLIST_URL = local.service_inputs["authentication"].waitlist_url
    # The account platform signs people in for the other platforms, which are OAuth clients: each
    # redeems the codes it receives at its callback. Authentication refuses to start unless
    # SERVICE_TOKEN_CALLERS admits every caller named here.
    ACCOUNT_PLATFORM_CALLER = local.platform_callers.account
    OAUTH_CLIENTS = jsonencode({ for platform, caller in local.platform_callers : platform => {
      redirectURI = "https://${local.platform_edges[platform].host}/auth/callback"
      caller      = caller
    } if platform != "account" })
  })
  authentication_secret_env = merge(local.database_secret_env, {
    REST_RATE_LIMIT_STORE_PASSWORD = { secret = local.counter_store_values.auth.usersExistingSecret, key = "limiter" }
    WAITLIST_SECRET                = { secret = "secrets", key = "WAITLIST_SECRET" }
  })
  # Each platform calls Authentication as its web workload's service account.
  platform_callers = { for platform in keys(local.platforms) : platform => "system:serviceaccount:${platform}:web" }
}

module "authentication_rest" {
  source = "../../../modules/cluster-workload"
  count  = var.custom_resources ? 1 : 0

  name             = "rest"
  namespace        = kubernetes_namespace_v1.service["authentication"].metadata[0].name
  image            = local.release_image["authentication/rest"]
  port             = local.service_port
  tls              = { secret = kubernetes_manifest.service_server_certificate["authentication/rest"].manifest.spec.secretName }
  service_ca       = kubernetes_manifest.service_trust_bundle[0].manifest.metadata.name
  http_health_path = "/v2/ping"
  env              = local.authentication_env
  secret_env       = local.authentication_secret_env
  service_tokens   = { (local.json_keys_env.SERVICE_TOKEN_AUDIENCE) = "SERVICE_TOKEN_PATH" }
  ca_secret        = kubernetes_manifest.database_server_certificate["authentication"].manifest.spec.secretName
  # Argon2 bursts above the request: the pod has no CPU limit, and a third pod takes a long burst.
  # Two keep sign-in up through a lost pod or node. Each hashes one password at a time.
  resources       = { cpu = "100m", memory = "512Mi" }
  replicas        = { min = 2, max = 3 }
  labels          = local.database_clients
  pod_annotations = local.database_client_annotations

  depends_on = [kubernetes_job_v1.migrations, kubernetes_manifest.secrets]
}

# The platforms and Authentication's smoke and health checks call the API. It calls JSON Keys,
# reaches the issuer's keys through Google's restricted API addresses and the mail relay
# (egress.tf), and counts its rate limits in the counter store.
resource "kubernetes_network_policy_v1" "authentication_rest" {
  metadata {
    name      = "rest"
    namespace = kubernetes_namespace_v1.service["authentication"].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "rest" }
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      dynamic "from" {
        for_each = local.platforms

        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = from.key }
          }
          pod_selector {
            match_labels = { "app.kubernetes.io/name" = "web" }
          }
        }
      }
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
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "json-keys" }
        }
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "grpc" }
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

    egress {
      to {
        pod_selector {
          match_labels = local.counter_store_pods
        }
      }

      ports {
        port     = "6379"
        protocol = "TCP"
      }
    }
  }
}
