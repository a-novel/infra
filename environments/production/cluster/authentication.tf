# Authentication on the cluster, which serves no one until the cutover (a-novel/.github#522). It runs
# one pod, which holds the in-memory rate limits.
locals {
  authentication_smtp = local.service_inputs["authentication"].smtp
  # Registration and account emails, which the API and the maintenance Jobs send, and whose links
  # open Studio on its own host. The relay admits them by the NAT address, so they carry no SMTP
  # credential. RFC 5321 gives each SMTP command minutes, and no request waits for a send.
  authentication_mail_env = {
    PLATFORM_AUTH_URL   = "https://${local.platform_edges.studio.host}"
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
    REST_PORT              = "8080"
    SERVICE_JSON_KEYS_HOST = "grpc.json-keys.svc"
    SERVICE_JSON_KEYS_PORT = local.json_keys_env.GRPC_PORT
    SERVICE_TOKEN_ISSUER   = local.service_token_issuer
    SERVICE_TOKEN_AUDIENCE = "authentication"
    SERVICE_TOKEN_CALLERS = join(",", concat(
      [for platform in keys(local.platforms) : "system:serviceaccount:${platform}:web"],
      ["system:serviceaccount:authentication:smoke"],
    ))
  })
}

module "authentication_rest" {
  source = "../../../modules/cluster-workload"
  count  = var.custom_resources ? 1 : 0

  name             = "rest"
  namespace        = kubernetes_namespace_v1.service["authentication"].metadata[0].name
  image            = local.release_image["authentication/rest"]
  port             = 8080
  http_health_path = "/v2/ping"
  env              = local.authentication_env
  secret_env       = local.database_secret_env
  service_tokens   = { (local.json_keys_env.SERVICE_TOKEN_AUDIENCE) = "SERVICE_TOKEN_PATH" }
  ca_secret        = kubernetes_manifest.database_server_certificate["authentication"].manifest.spec.secretName
  # Argon2 bursts above the request: the pod has no CPU limit.
  resources       = { cpu = "250m", memory = "512Mi" }
  replicas        = { min = 1, max = 1 }
  labels          = local.database_clients
  pod_annotations = local.database_client_annotations

  depends_on = [kubernetes_job_v1.migrations]
}

# The platforms and Authentication's smoke and health checks call the API. It calls JSON Keys, and
# reaches the issuer's keys through Google's restricted API addresses and the mail relay
# (egress.tf).
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
        port     = "8080"
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
        port     = "8080"
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
