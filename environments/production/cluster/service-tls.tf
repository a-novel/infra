# The service APIs serve TLS from a CA we issue, as the databases do, so passwords, codes and tokens
# cross the cluster only over TLS (RFC 6749 §3.2 and §10.3). trust-manager copies the CA's
# certificate into each namespace that calls a service.
locals {
  # Each service API that serves TLS, by namespace: its workload, whose Service name its certificate
  # names.
  service_tls = {
    authentication = "rest"
    genai          = "grpc"
    json-keys      = "grpc"
  }
  # The port each API serves TLS on.
  service_port = 8443
}

# It reads the CA in its own namespace. GKE's control plane reaches pods on 443 and 10250 only, so
# its webhook listens on 10250, as cert-manager's does.
resource "helm_release" "trust_manager" {
  name       = "trust-manager"
  namespace  = kubernetes_namespace_v1.addon["cert-manager"].metadata[0].name
  repository = "oci://quay.io/jetstack/charts"
  chart      = "trust-manager"
  version    = "v0.25.0"

  values = [yamlencode({
    crds           = { enabled = true, keep = true }
    image          = local.images.trust_manager
    defaultPackage = { enabled = false }
    app = {
      trust   = { namespace = kubernetes_namespace_v1.addon["cert-manager"].metadata[0].name }
      webhook = { port = 10250 }
    }
  })]

  depends_on = [module.database_operator]
}

# The CA keeps its key when cert-manager renews it, so a caller that loaded the previous certificate
# still verifies until that copy expires.
resource "kubernetes_manifest" "service_ca" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "services-ca", namespace = kubernetes_namespace_v1.addon["cert-manager"].metadata[0].name }
    spec = {
      isCA       = true
      commonName = "A-Novel services"
      secretName = "services-ca"
      duration   = "87600h"
      privateKey = { algorithm = "ECDSA", size = 256, rotationPolicy = "Never" }
      issuerRef  = { group = "cert-manager.io", kind = "ClusterIssuer", name = kubernetes_manifest.self_signed_issuer[0].manifest.metadata.name }
    }
  }
}

resource "kubernetes_manifest" "service_issuer" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "services" }
    spec       = { ca = { secretName = kubernetes_manifest.service_ca[0].manifest.spec.secretName } }
  }
}

# Each certificate names its API's in-cluster host, so one service's key cannot pass for another's.
# The server loads it again at renewal.
resource "kubernetes_manifest" "service_server_certificate" {
  for_each = var.custom_resources ? local.service_tls : {}

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "${each.value}-server", namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name }
    spec = {
      secretName = "${each.value}-server-tls"
      usages     = ["server auth"]
      dnsNames   = ["${each.value}.${kubernetes_namespace_v1.service[each.key].metadata[0].name}.svc"]
      issuerRef  = { group = "cert-manager.io", kind = "ClusterIssuer", name = kubernetes_manifest.service_issuer[0].manifest.metadata.name }
    }
  }

  # A server finds its certificate as it starts.
  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}

# Every service namespace receives the CA's certificate in a ConfigMap named after the Bundle, and a
# workload that calls a service API mounts it. The CA keeps its key, so a renewal changes no caller's trust.
resource "kubernetes_manifest" "service_trust_bundle" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "trust.cert-manager.io/v1alpha1"
    kind       = "Bundle"
    metadata   = { name = "services-ca" }
    spec = {
      sources = [{ secret = { name = kubernetes_manifest.service_ca[0].manifest.spec.secretName, key = "ca.crt" } }]
      target = {
        configMap         = { key = "ca.crt" }
        namespaceSelector = { matchExpressions = [{ key = "kubernetes.io/metadata.name", operator = "In", values = sort(var.namespaces) }] }
      }
    }
  }

  # A caller finds the certificate as it starts.
  wait {
    condition {
      type   = "Synced"
      status = "True"
    }
  }

  depends_on = [helm_release.trust_manager]
}
