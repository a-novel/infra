# Each service runs inside its own budget (a-novel/.github#522): the CPU and memory its pods request,
# and how many run. The node pool is shared, so a budget keeps one service's spike or stuck
# autoscaler from taking the room the others need.
resource "kubernetes_resource_quota_v1" "service" {
  for_each = var.service_budgets

  metadata {
    name      = "budget"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  spec {
    hard = {
      "requests.cpu"    = each.value.cpu
      "requests.memory" = each.value.memory
      pods              = each.value.pods
    }
  }

  depends_on = [kubernetes_limit_range_v1.service]
}

# A quota on requests refuses a pod whose containers set none, such as CloudNativePG's backup
# sidecar, so each such container gets a small request, and no limit.
resource "kubernetes_limit_range_v1" "service" {
  for_each = var.namespaces

  metadata {
    name      = "defaults"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  spec {
    limit {
      type            = "Container"
      default_request = { cpu = "10m", memory = "64Mi" }
    }
  }
}
