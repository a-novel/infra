# Studio on the cluster, which serves no one until the cutover (a-novel/.github#522). Visitors reach
# it on its own host through a Gateway on Google's global load balancer (a-novel/infra#1201), at the
# address, certificate and TLS policy foundation holds.
locals {
  studio_edge = data.terraform_remote_state.foundation.outputs.studio_edge
  studio_host = local.studio_edge.host
  studio_env = merge(local.telemetry_env["studio"].api, {
    AUTHENTICATION_SERVICE_URL = "http://rest.authentication.svc:${local.authentication_env.REST_PORT}"
    # The load balancer appends the visitor's address, then its own, so the second entry from the
    # right is the only one a visitor cannot forge. Authentication rate-limits by the address Studio
    # forwards.
    ADDRESS_HEADER = "X-Forwarded-For"
    XFF_DEPTH      = "2"
    # The load balancer ends TLS, so Studio checks form posts against its public origin.
    ORIGIN = "https://${local.studio_host}"
  })
  # The global load balancer's proxies and health checks reach the pods from these ranges.
  # https://cloud.google.com/load-balancing/docs/firewall-rules
  load_balancer_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
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

# The load balancer reaches Studio, which calls Authentication's API and reads the planned downtime
# document from GitHub (egress.tf).
resource "kubernetes_network_policy_v1" "studio_web" {
  metadata {
    name      = "web"
    namespace = kubernetes_namespace_v1.service["studio"].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "web" }
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      dynamic "from" {
        for_each = local.load_balancer_ranges

        content {
          ip_block {
            cidr = from.value
          }
        }
      }

      ports {
        port     = tostring(module.studio_web.service.port)
        protocol = "TCP"
      }
    }

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

# The Gateway answers on foundation's address with its certificate map, which serves Studio's
# certificate for its host. Its kinds exist once the cluster runs the Gateway API.
resource "kubernetes_manifest" "studio_gateway" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name        = "studio"
      namespace   = kubernetes_namespace_v1.service["studio"].metadata[0].name
      annotations = { "networking.gke.io/certmap" = local.studio_edge.certificate_map }
    }
    spec = {
      gatewayClassName = "gke-l7-global-external-managed"
      addresses        = [{ type = "NamedAddress", value = local.studio_edge.address_name }]
      listeners = [
        { name = "https", protocol = "HTTPS", port = 443, hostname = local.studio_host },
        { name = "http", protocol = "HTTP", port = 80, hostname = local.studio_host },
      ]
    }
  }
}

# The load balancer accepts only foundation's TLS policy, TLS 1.2 or above.
resource "kubernetes_manifest" "studio_gateway_policy" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "networking.gke.io/v1"
    kind       = "GCPGatewayPolicy"
    metadata   = { name = "studio", namespace = kubernetes_manifest.studio_gateway[0].manifest.metadata.namespace }
    spec = {
      default   = { sslPolicy = local.studio_edge.ssl_policy }
      targetRef = { group = "gateway.networking.k8s.io", kind = "Gateway", name = kubernetes_manifest.studio_gateway[0].manifest.metadata.name }
    }
  }
}

resource "kubernetes_manifest" "studio_route" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "web", namespace = kubernetes_manifest.studio_gateway[0].manifest.metadata.namespace }
    spec = {
      parentRefs = [{ name = kubernetes_manifest.studio_gateway[0].manifest.metadata.name, sectionName = "https" }]
      hostnames  = [local.studio_host]
      rules      = [{ backendRefs = [module.studio_web.service] }]
    }
  }
}

# Plain HTTP only redirects to HTTPS.
resource "kubernetes_manifest" "studio_redirect" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "web-redirect", namespace = kubernetes_manifest.studio_gateway[0].manifest.metadata.namespace }
    spec = {
      parentRefs = [{ name = kubernetes_manifest.studio_gateway[0].manifest.metadata.name, sectionName = "http" }]
      hostnames  = [local.studio_host]
      rules      = [{ filters = [{ type = "RequestRedirect", requestRedirect = { scheme = "https", statusCode = 301 } }] }]
    }
  }
}

# The load balancer checks the pods on their probes' path, since Studio's root redirects visitors.
resource "kubernetes_manifest" "studio_health_check" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "networking.gke.io/v1"
    kind       = "HealthCheckPolicy"
    metadata   = { name = "web", namespace = kubernetes_namespace_v1.service["studio"].metadata[0].name }
    spec = {
      default = {
        config = {
          type            = "HTTP"
          httpHealthCheck = { port = module.studio_web.service.port, requestPath = "/ping" }
        }
      }
      targetRef = { group = "", kind = "Service", name = module.studio_web.service.name }
    }
  }
}
