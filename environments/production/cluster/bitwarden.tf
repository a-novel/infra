# External Secrets reads every Bitwarden secret through the Bitwarden SDK server, which serves only
# TLS. A private CA that cert-manager bootstraps signs the server's certificate, and each secret
# store will trust that CA from the `bitwarden-ca` Secret.
resource "kubernetes_manifest" "bitwarden_bootstrap_issuer" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata   = { name = "bitwarden-bootstrap", namespace = kubernetes_namespace_v1.addon["external-secrets"].metadata[0].name }
    spec       = { selfSigned = {} }
  }

  depends_on = [module.database_operator]
}

resource "kubernetes_manifest" "bitwarden_ca" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "bitwarden-ca", namespace = kubernetes_namespace_v1.addon["external-secrets"].metadata[0].name }
    spec = {
      isCA       = true
      commonName = "bitwarden-sdk-server-ca"
      secretName = "bitwarden-ca"
      privateKey = { algorithm = "ECDSA", size = 256 }
      issuerRef  = { kind = "Issuer", name = kubernetes_manifest.bitwarden_bootstrap_issuer[0].manifest.metadata.name }
    }
  }
}

resource "kubernetes_manifest" "bitwarden_ca_issuer" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Issuer"
    metadata   = { name = "bitwarden-ca", namespace = kubernetes_namespace_v1.addon["external-secrets"].metadata[0].name }
    spec       = { ca = { secretName = kubernetes_manifest.bitwarden_ca[0].manifest.spec.secretName } }
  }
}

# The SDK server mounts this Secret, so the release waits until cert-manager has issued it.
resource "kubernetes_manifest" "bitwarden_tls" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "bitwarden-tls", namespace = kubernetes_namespace_v1.addon["external-secrets"].metadata[0].name }
    spec = {
      secretName = "bitwarden-tls-certs"
      dnsNames = [
        "bitwarden-sdk-server",
        "bitwarden-sdk-server.external-secrets.svc",
        "bitwarden-sdk-server.external-secrets.svc.cluster.local",
      ]
      privateKey = { algorithm = "ECDSA", size = 256 }
      issuerRef  = { kind = "Issuer", name = kubernetes_manifest.bitwarden_ca_issuer[0].manifest.metadata.name }
    }
  }

  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}
