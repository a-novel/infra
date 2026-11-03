# Temporary: names the cluster's Gateway API bundle version and the redirect codes its HTTPRoute CRD
# accepts in this pull request's plan log, to prove the CRDs accept 308. Removed before review.
data "kubernetes_resource" "httproute_crd" {
  api_version = "apiextensions.k8s.io/v1"
  kind        = "CustomResourceDefinition"

  metadata {
    name = "httproutes.gateway.networking.k8s.io"
  }
}

resource "terraform_data" "gateway_api_probe" {
  for_each = toset([try(join(" ", concat(
    [data.kubernetes_resource.httproute_crd.object.metadata.annotations["gateway.networking.k8s.io/bundle-version"]],
    [for code in flatten([for version in data.kubernetes_resource.httproute_crd.object.spec.versions : version.schema.openAPIV3Schema.properties.spec.properties.rules.items.properties.filters.items.properties.requestRedirect.properties.statusCode.enum if version.name == "v1"]) : tostring(code)],
  )), "unreadable")])
}
