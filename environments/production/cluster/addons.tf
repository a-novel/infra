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

# Issues the certificates of the Barman Cloud plugin and the Bitwarden SDK server. Its leases stay in
# its own namespace.
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  namespace  = kubernetes_namespace_v1.addon["cert-manager"].metadata[0].name
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v1.21.2"

  values = [yamlencode({
    crds            = { enabled = true, keep = true }
    global          = { leaderElection = { namespace = "cert-manager" } }
    image           = local.images.cert_manager_controller
    webhook         = { image = local.images.cert_manager_webhook }
    cainjector      = { image = local.images.cert_manager_cainjector }
    startupapicheck = { enabled = false }
  })]
}

resource "helm_release" "cloudnative_pg" {
  name       = "cloudnative-pg"
  namespace  = kubernetes_namespace_v1.addon["cnpg-system"].metadata[0].name
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  version    = "0.29.1"

  values = [yamlencode({
    image = local.images.cloudnative_pg
  })]
}

# Its chart names the registry apart from the repository. It needs cert-manager's resources and the
# operator it plugs into.
resource "helm_release" "plugin_barman_cloud" {
  name       = "plugin-barman-cloud"
  namespace  = kubernetes_namespace_v1.addon["cnpg-system"].metadata[0].name
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "plugin-barman-cloud"
  version    = "0.8.1"

  values = [yamlencode({
    for key, image in { image = local.images.plugin_barman_cloud, sidecarImage = local.images.plugin_barman_cloud_sidecar } : key => {
      registry                = split("/", image.repository)[0]
      repository              = join("/", slice(split("/", image.repository), 1, length(split("/", image.repository))))
      tag                     = image.tag
    }
  })]

  depends_on = [helm_release.cert_manager, helm_release.cloudnative_pg]
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  namespace  = kubernetes_namespace_v1.addon["external-secrets"].metadata[0].name
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = "2.13.0"

  values = [yamlencode({
    image          = local.images.external_secrets
    webhook        = { image = local.images.external_secrets }
    certController = { image = local.images.external_secrets }
    # Its chart sets no security context, so it gets the one Pod Security's restricted level asks
    # for. Its image already runs as a non-root user.
    bitwarden-sdk-server = {
      enabled            = var.custom_resources
      image              = local.images.bitwarden_sdk_server
      podSecurityContext = { runAsNonRoot = true, seccompProfile = { type = "RuntimeDefault" } }
      securityContext    = { allowPrivilegeEscalation = false, capabilities = { drop = ["ALL"] } }
    }
  })]

  depends_on = [kubernetes_manifest.bitwarden_tls]
}
