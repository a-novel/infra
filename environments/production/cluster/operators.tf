# Foundation's database operators read each service's namespace through Kubernetes' built-in view
# role: its pods and their logs, events and workloads, never its Secrets. Foundation's IAM only lets
# them connect to the control plane.
locals {
  operators = provider::terraform::decode_tfvars(file("${path.module}/../foundation/terraform.tfvars")).database_operator_principals
}

resource "kubernetes_role_binding_v1" "operators" {
  for_each = var.namespaces

  metadata {
    name      = "operators"
    namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "view"
  }

  # GKE names each Google identity by its email. A group binds only once the cluster reads Google
  # Groups for RBAC.
  dynamic "subject" {
    for_each = local.operators

    content {
      api_group = "rbac.authorization.k8s.io"
      kind      = title(split(":", subject.value)[0])
      name      = split(":", subject.value)[1]
    }
  }
}
