# Studio on the cluster, which serves no one until the cutover (a-novel/.github#522). Visitors reach
# it on its own host once the Gateway serves it (a-novel/infra#1201), through Google's load balancer.
locals {
  studio_host = "studio.agorastoryverse.com"
  studio_env = {
    AUTHENTICATION_SERVICE_URL = "http://rest.authentication.svc:${local.authentication_env.REST_PORT}"
    # The load balancer appends the visitor's address, then its own, so the second entry from the
    # right is the only one a visitor cannot forge. Authentication rate-limits by the address Studio
    # forwards.
    ADDRESS_HEADER = "X-Forwarded-For"
    XFF_DEPTH      = "2"
    # The load balancer ends TLS, so Studio checks form posts against its public origin.
    ORIGIN = "https://${local.studio_host}"
    # Alloy carries the telemetry once it runs (a-novel/infra#1206).
    OTEL = "false"
  }
}

module "studio_web" {
  source = "../../../modules/cluster-workload"

  name             = "web"
  namespace        = kubernetes_namespace_v1.service["studio"].metadata[0].name
  image            = local.release_image["studio/web"]
  port             = 3000
  http_health_path = "/ping"
  env              = local.studio_env
  service_tokens   = { (local.authentication_env.SERVICE_TOKEN_AUDIENCE) = "SERVICE_TOKEN_PATH" }
  resources        = { cpu = "100m", memory = "512Mi" }
  replicas         = { min = 1, max = 2 }
}

# Studio calls Authentication's API. The Gateway's traffic and the downtime document's host arrive
# with a-novel/infra#1201 and a-novel/infra#1200.
resource "kubernetes_network_policy_v1" "studio_web" {
  metadata {
    name      = "web"
    namespace = kubernetes_namespace_v1.service["studio"].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "web" }
    }
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "authentication" }
        }
        pod_selector {
          match_labels = { "app.kubernetes.io/name" = "rest" }
        }
      }

      ports {
        port     = local.authentication_env.REST_PORT
        protocol = "TCP"
      }
    }
  }
}
