# The databases serve TLS from a CA we issue, which the services trust. CloudNativePG's own CA renews
# every few months, and a running service loads its trusted roots once, so it would stop trusting
# its database at each renewal.
resource "kubernetes_manifest" "self_signed_issuer" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "self-signed" }
    spec       = { selfSigned = {} }
  }

  depends_on = [module.database_operator]
}

# The CA keeps its key when cert-manager renews it, so a service that loaded the previous
# certificate still verifies until that copy expires.
resource "kubernetes_manifest" "database_ca" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "databases-ca", namespace = kubernetes_namespace_v1.addon["cert-manager"].metadata[0].name }
    spec = {
      isCA       = true
      commonName = "A-Novel databases"
      secretName = "databases-ca"
      duration   = "87600h"
      privateKey = { algorithm = "ECDSA", size = 256, rotationPolicy = "Never" }
      issuerRef  = { group = "cert-manager.io", kind = "ClusterIssuer", name = kubernetes_manifest.self_signed_issuer[0].manifest.metadata.name }
    }
  }
}

resource "kubernetes_manifest" "database_issuer" {
  count = var.custom_resources ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "databases" }
    spec       = { ca = { secretName = kubernetes_manifest.database_ca[0].manifest.spec.secretName } }
  }
}

# Each database's certificate names its own namespace, so one database's key cannot pass for
# another's. Its Secret's label makes the instances reload it at each renewal.
resource "kubernetes_manifest" "database_server_certificate" {
  for_each = var.custom_resources ? var.databases : {}

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "database-server", namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name }
    spec = {
      secretName     = "database-server-tls"
      secretTemplate = { labels = { "cnpg.io/reload" = "" } }
      usages         = ["server auth"]
      dnsNames       = [local.database_env[each.key].POSTGRES_HOST]
      issuerRef      = { group = "cert-manager.io", kind = "ClusterIssuer", name = kubernetes_manifest.database_issuer[0].manifest.metadata.name }
    }
  }
}

locals {
  # The name each database's replication certificate carries, which only its own database maps to
  # streaming_replica.
  database_replication_names = { for service in keys(var.databases) : service => "streaming-replica.${service}" }
}

# Each database's replica authenticates as streaming_replica with this certificate. The operator
# generates no client CA, so a database that replaces another never meets the CA the old one used.
resource "kubernetes_manifest" "database_replication_certificate" {
  for_each = var.custom_resources ? var.databases : {}

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata   = { name = "database-replication", namespace = kubernetes_namespace_v1.service[each.key].metadata[0].name }
    spec = {
      secretName     = "database-replication-tls"
      secretTemplate = { labels = { "cnpg.io/reload" = "" } }
      usages         = ["client auth"]
      commonName     = local.database_replication_names[each.key]
      issuerRef      = { group = "cert-manager.io", kind = "ClusterIssuer", name = kubernetes_manifest.database_issuer[0].manifest.metadata.name }
    }
  }

  # A new database finds the certificate as it starts.
  wait {
    condition {
      type   = "Ready"
      status = "True"
    }
  }
}
