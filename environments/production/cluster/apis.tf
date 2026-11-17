# Who may call each service API. An API admits only its callers and its namespace's smoke check: by
# their service accounts, which its SERVICE_TOKEN_CALLERS lists, and by their pods, which its network
# policy admits. Each caller's own policy reaches only the APIs it calls. A service that trusts a
# forwarded visitor header lists only the platforms.
locals {
  # Each API by "<namespace>/<workload>", with its callers named the same way. tokens tells whether it
  # verifies their service tokens, against the keys it reads from Google. metrics_port opens the port
  # GKE reads the calls in flight from, for an API that scales on them. JSON Keys' public keys take
  # no token, so the policy alone decides who reads them.
  apis = {
    "authentication/rest"   = { callers = local.platform_workloads, tokens = true }
    "genai/grpc"            = { callers = ["narrative-engine/rest"], tokens = true, metrics_port = 9090 }
    "json-keys/grpc"        = { callers = ["authentication/rest", "narrative-engine/rest", "profile/rest"], tokens = true }
    "json-keys/rest"        = { callers = local.platform_workloads, tokens = false }
    "narrative-engine/rest" = { callers = ["studio/web"], tokens = true }
    "profile/rest"          = { callers = local.platform_workloads, tokens = true }
  }
  platform_workloads = [for platform in keys(local.platforms) : "${platform}/web"]

  service_apis = { for key in keys(local.apis) : key => { namespace = split("/", key)[0], workload = split("/", key)[1] } }
  # The APIs each caller calls: the table inverted.
  calls = { for caller in distinct(flatten([for api in values(local.apis) : api.callers])) : caller => [for key, api in local.apis : key if contains(api.callers, caller)] }
  # Each API's SERVICE_TOKEN_CALLERS: its callers' service accounts, then its smoke check's.
  token_callers = { for key, api in local.apis : key => join(",", [for caller in concat(sort(api.callers), ["${local.service_apis[key].namespace}/smoke"]) : "system:serviceaccount:${replace(caller, "/", ":")}"]) }
}

# Each API takes its callers and its smoke check on its TLS port. It reaches the APIs it calls, the
# issuer's keys through Google's restricted API addresses when it verifies service tokens, and its
# namespace's counter store when it has one. A caller's internet hosts are in egress.tf.
resource "kubernetes_network_policy_v1" "api" {
  for_each = local.service_apis

  metadata {
    name      = each.value.workload
    namespace = kubernetes_namespace_v1.service[each.value.namespace].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = each.value.workload }
    }
    policy_types = ["Ingress", "Egress"]

    ingress {
      dynamic "from" {
        for_each = sort(local.apis[each.key].callers)

        content {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = split("/", from.value)[0] }
          }
          pod_selector {
            match_labels = { "app.kubernetes.io/name" = split("/", from.value)[1] }
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

    # GKE reads the calls in flight from a source it does not document: a node, or a pod in
    # kube-system.
    dynamic "ingress" {
      for_each = try([local.apis[each.key].metrics_port], [])

      content {
        from {
          ip_block {
            cidr = local.cluster.node_range
          }
        }
        from {
          namespace_selector {
            match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
          }
        }

        ports {
          port     = tostring(ingress.value)
          protocol = "TCP"
        }
      }
    }

    dynamic "egress" {
      for_each = contains(keys(local.calls), each.key) ? [local.calls[each.key]] : []

      content {
        dynamic "to" {
          for_each = egress.value

          content {
            namespace_selector {
              match_labels = { "kubernetes.io/metadata.name" = local.service_apis[to.value].namespace }
            }
            pod_selector {
              match_labels = { "app.kubernetes.io/name" = local.service_apis[to.value].workload }
            }
          }
        }

        ports {
          port     = tostring(local.service_port)
          protocol = "TCP"
        }
      }
    }

    dynamic "egress" {
      for_each = local.apis[each.key].tokens ? [local.cluster.google_api_ranges] : []

      content {
        dynamic "to" {
          for_each = egress.value

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

    dynamic "egress" {
      for_each = contains(var.counter_stores, each.value.namespace) ? [local.counter_store_pods] : []

      content {
        to {
          pod_selector {
            match_labels = egress.value
          }
        }

        ports {
          port     = "6379"
          protocol = "TCP"
        }
      }
    }
  }
}
