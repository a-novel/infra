# Issues the Barman Cloud plugin's certificates. Its leases stay in its own namespace. The chart
# comes from the OCI registry, which cert-manager publishes first. Alloy discovers the controller by
# its own annotations, not the chart's prometheus.io ones, and scrapes only its metrics port.
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  namespace  = var.namespaces.cert_manager
  repository = "oci://quay.io/jetstack/charts"
  chart      = "cert-manager"
  version    = "v1.21.3"

  values = [yamlencode({
    crds            = { enabled = true, keep = true }
    global          = { leaderElection = { namespace = var.namespaces.cert_manager } }
    image           = var.images.cert_manager_controller
    podAnnotations  = { "k8s.grafana.com/scrape" = "true", "k8s.grafana.com/metrics.portName" = "http-metrics" }
    webhook         = { image = var.images.cert_manager_webhook }
    cainjector      = { image = var.images.cert_manager_cainjector }
    startupapicheck = { enabled = false }
  })]
}

resource "helm_release" "cloudnative_pg" {
  name       = "cloudnative-pg"
  namespace  = var.namespaces.cloudnative_pg
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "cloudnative-pg"
  version    = "0.29.1"

  values = [yamlencode({
    image = var.images.cloudnative_pg
  })]
}

# Its chart names the registry apart from the repository. It needs cert-manager's resources and the
# operator it plugs into.
resource "helm_release" "plugin_barman_cloud" {
  name       = "plugin-barman-cloud"
  namespace  = var.namespaces.cloudnative_pg
  repository = "https://cloudnative-pg.github.io/charts"
  chart      = "plugin-barman-cloud"
  version    = "0.8.1"

  values = [yamlencode({
    for key, image in { image = var.images.plugin_barman_cloud, sidecarImage = var.images.plugin_barman_cloud_sidecar } : key => {
      registry                = split("/", image.repository)[0]
      repository              = join("/", slice(split("/", image.repository), 1, length(split("/", image.repository))))
      tag                     = image.tag
    }
  })]

  depends_on = [helm_release.cert_manager, helm_release.cloudnative_pg]
}

output "barman_plugin" {
  description = "The name the Barman Cloud plugin registers, which a database's Cluster names to archive and restore through it."
  value       = "barman-cloud.cloudnative-pg.io"
}
