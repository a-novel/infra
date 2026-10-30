# The operators the workloads and databases rely on, each in its own namespace. Renovate moves each
# chart with its images, after a review.
locals {
  addon_namespaces = toset(["cert-manager", "cnpg-system", "external-secrets"])

  # quay.io/jetstack/x:tag@digest pulls as <foundation's quay.io cache>/jetstack/x, with the tag
  # tag@digest: every chart renders an image as repository:tag.
  image_parts = { for name, reference in var.addon_images : name => regex("^(?P<host>[^/]+)/(?P<path>[^:]+):(?P<tag>.+)$", reference) }
  images = {
    for name, parts in local.image_parts : name => {
      repository = "${local.cluster.image_registries[parts.host]}/${parts.path}"
      tag        = parts.tag
    }
  }
}

resource "kubernetes_namespace_v1" "addon" {
  for_each = local.addon_namespaces

  metadata {
    name   = each.key
    labels = local.pod_security
  }

  lifecycle {
    prevent_destroy = true
  }
}

# cert-manager, CloudNativePG and its Barman Cloud plugin, as the recovery drill runs them.
module "database_operator" {
  source = "../../../modules/database-operator"

  images = local.images
  namespaces = {
    cert_manager   = kubernetes_namespace_v1.addon["cert-manager"].metadata[0].name
    cloudnative_pg = kubernetes_namespace_v1.addon["cnpg-system"].metadata[0].name
  }
}

moved {
  from = helm_release.cert_manager
  to   = module.database_operator.helm_release.cert_manager
}

moved {
  from = helm_release.cloudnative_pg
  to   = module.database_operator.helm_release.cloudnative_pg
}

moved {
  from = helm_release.plugin_barman_cloud
  to   = module.database_operator.helm_release.plugin_barman_cloud
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  namespace  = kubernetes_namespace_v1.addon["external-secrets"].metadata[0].name
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "2.14.0"

  values = [yamlencode({
    image          = local.images.external_secrets
    webhook        = { image = local.images.external_secrets }
    certController = { image = local.images.external_secrets }
  })]
}
