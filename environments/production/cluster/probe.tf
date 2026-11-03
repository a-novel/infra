# Temporary: shows the cluster's Gateway API bundle version in this pull request's plan, to prove the
# CRDs accept 308. Removed before review.
data "kubernetes_resource" "httproute_crd" {
  api_version = "apiextensions.k8s.io/v1"
  kind        = "CustomResourceDefinition"

  metadata {
    name = "httproutes.gateway.networking.k8s.io"
  }
}

output "gateway_api_probe" {
  description = "The HTTPRoute CRD's bundle version and the redirect status codes it accepts."
  value = try({
    bundle = data.kubernetes_resource.httproute_crd.object.metadata.annotations["gateway.networking.k8s.io/bundle-version"]
    codes  = [for version in data.kubernetes_resource.httproute_crd.object.spec.versions : version.schema.openAPIV3Schema.properties.spec.properties.rules.items.properties.filters.items.properties.requestRedirect.properties.statusCode.enum if version.name == "v1"]
  }, null)
}
