# The platforms on the cluster. Visitors reach each on its own host through its own Gateway on
# Google's global load balancer (a-novel/infra#1201), at the address, certificate and TLS policy
# foundation holds. Each runs one web workload in the namespace named after it.
locals {
  platform_edges = data.terraform_remote_state.foundation.outputs.platform_edges
  # Each platform's own settings, on top of those every platform takes.
  platforms = {
    # The app list opens Studio.
    account = { STUDIO_URL = "https://${local.platform_edges.studio.host}" }
    # The account name opens the account platform.
    studio = { ACCOUNT_URL = "https://${local.platform_edges.account.host}" }
  }
  platform_env = { for platform, settings in local.platforms : platform => merge(local.telemetry_env[platform].api, {
    AUTHENTICATION_SERVICE_URL = "http://rest.authentication.svc:${local.authentication_env.REST_PORT}"
    # The load balancer appends the visitor's address, then its own, so the second entry from the
    # right is the only one a visitor cannot forge. Authentication rate-limits by the address the
    # platform forwards.
    ADDRESS_HEADER = "X-Forwarded-For"
    XFF_DEPTH      = "2"
    # The load balancer ends TLS, so the platform checks form posts against its public origin.
    ORIGIN = "https://${local.platform_edges[platform].host}"
  }, settings) }
  # The global load balancer's proxies and health checks reach the pods from these ranges.
  # https://cloud.google.com/load-balancing/docs/firewall-rules
  load_balancer_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
}

module "platform_web" {
  source   = "../../../modules/cluster-workload"
  for_each = local.platforms

  name             = "web"
  namespace        = kubernetes_namespace_v1.service[each.key].metadata[0].name
  image            = local.release_image["${each.key}/web"]
  port             = 3000
  http_health_path = "/ping"
  env              = local.platform_env[each.key]
  service_tokens   = { (local.authentication_env.SERVICE_TOKEN_AUDIENCE) = "SERVICE_TOKEN_PATH" }
  resources        = { cpu = "100m", memory = "512Mi" }
  replicas         = { min = 1, max = 2 }
}

moved {
  from = module.studio_web
  to   = module.platform_web["studio"]
}

# The load balancer reaches each platform, which calls Authentication's API and reads the planned
# downtime document from GitHub (egress.tf).
resource "kubernetes_network_policy_v1" "platform_web" {
  for_each = local.platforms

  metadata {
    name      = "web"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
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
        port     = tostring(module.platform_web[each.key].service.port)
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

moved {
  from = kubernetes_network_policy_v1.studio_web
  to   = kubernetes_network_policy_v1.platform_web["studio"]
}

# Each Gateway answers on foundation's address with its certificate map, which serves the
# platform's certificate for its host. Its kinds exist once the cluster runs the Gateway API.
resource "kubernetes_manifest" "platform_gateway" {
  for_each = var.custom_resources ? local.platforms : {}

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name        = each.key
      namespace   = kubernetes_namespace_v1.service[each.key].metadata[0].name
      annotations = { "networking.gke.io/certmap" = local.platform_edges[each.key].certificate_map }
    }
    spec = {
      gatewayClassName = "gke-l7-global-external-managed"
      addresses        = [{ type = "NamedAddress", value = local.platform_edges[each.key].address_name }]
      listeners = [
        { name = "https", protocol = "HTTPS", port = 443, hostname = local.platform_edges[each.key].host },
        { name = "http", protocol = "HTTP", port = 80, hostname = local.platform_edges[each.key].host },
      ]
    }
  }
}

moved {
  from = kubernetes_manifest.studio_gateway[0]
  to   = kubernetes_manifest.platform_gateway["studio"]
}

# The load balancer accepts only foundation's TLS policy, TLS 1.2 or above.
resource "kubernetes_manifest" "platform_gateway_policy" {
  for_each = var.custom_resources ? local.platforms : {}

  manifest = {
    apiVersion = "networking.gke.io/v1"
    kind       = "GCPGatewayPolicy"
    metadata   = { name = each.key, namespace = kubernetes_manifest.platform_gateway[each.key].manifest.metadata.namespace }
    spec = {
      default   = { sslPolicy = local.platform_edges[each.key].ssl_policy }
      targetRef = { group = "gateway.networking.k8s.io", kind = "Gateway", name = kubernetes_manifest.platform_gateway[each.key].manifest.metadata.name }
    }
  }
}

moved {
  from = kubernetes_manifest.studio_gateway_policy[0]
  to   = kubernetes_manifest.platform_gateway_policy["studio"]
}

resource "kubernetes_manifest" "platform_route" {
  for_each = var.custom_resources ? local.platforms : {}

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "web", namespace = kubernetes_manifest.platform_gateway[each.key].manifest.metadata.namespace }
    spec = {
      parentRefs = [{ name = kubernetes_manifest.platform_gateway[each.key].manifest.metadata.name, sectionName = "https" }]
      hostnames  = [local.platform_edges[each.key].host]
      rules      = [{ backendRefs = [module.platform_web[each.key].service] }]
    }
  }
}

moved {
  from = kubernetes_manifest.studio_route[0]
  to   = kubernetes_manifest.platform_route["studio"]
}

# Plain HTTP only redirects to HTTPS.
resource "kubernetes_manifest" "platform_redirect" {
  for_each = var.custom_resources ? local.platforms : {}

  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata   = { name = "web-redirect", namespace = kubernetes_manifest.platform_gateway[each.key].manifest.metadata.namespace }
    spec = {
      parentRefs = [{ name = kubernetes_manifest.platform_gateway[each.key].manifest.metadata.name, sectionName = "http" }]
      hostnames  = [local.platform_edges[each.key].host]
      rules      = [{ filters = [{ type = "RequestRedirect", requestRedirect = { scheme = "https", statusCode = 301 } }] }]
    }
  }
}

moved {
  from = kubernetes_manifest.studio_redirect[0]
  to   = kubernetes_manifest.platform_redirect["studio"]
}

# The load balancer checks the pods on their probes' path, since a platform's root may redirect
# visitors.
resource "kubernetes_manifest" "platform_health_check" {
  for_each = var.custom_resources ? local.platforms : {}

  manifest = {
    apiVersion = "networking.gke.io/v1"
    kind       = "HealthCheckPolicy"
    metadata   = { name = "web", namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name }
    spec = {
      default = {
        config = {
          type            = "HTTP"
          httpHealthCheck = { port = module.platform_web[each.key].service.port, requestPath = "/ping" }
        }
      }
      targetRef = { group = "", kind = "Service", name = module.platform_web[each.key].service.name }
    }
  }
}

moved {
  from = kubernetes_manifest.studio_health_check[0]
  to   = kubernetes_manifest.platform_health_check["studio"]
}
