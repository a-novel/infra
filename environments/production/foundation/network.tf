locals {
  restricted_google_api_ranges = toset([
    "199.36.153.4/30",
    "34.126.0.0/18",
  ])

  restricted_google_vip_addresses = [
    "199.36.153.4",
    "199.36.153.5",
    "199.36.153.6",
    "199.36.153.7",
  ]

  # GKE pulls its system images from gcr.io.
  private_google_domains = {
    artifact_registry  = "pkg.dev."
    container_registry = "gcr.io."
  }
  # Nothing resolves Cloud Run's domain since Cloud Run retired. This deploy deletes its records and
  # unlocks its zone, so the next one can delete it (a-novel/infra#1208).
  retired_google_domains = { cloud_run = "run.app." }

  # The cluster's network resolves through these zones and the allowlist.
  dns_networks = [google_compute_network.cluster.id]
}

# Direct VPC egress logs no firewall verdict, so the network logs every lookup instead. The logs
# show the names each workload resolves.
resource "google_dns_policy" "production" {
  project = google_project.workload.project_id
  name    = "a-novel-production"

  enable_logging = true

  dynamic "networks" {
    for_each = local.dns_networks

    content {
      network_url = networks.value
    }
  }

  depends_on = [google_project_service.workload["dns.googleapis.com"]]
}

resource "google_dns_managed_zone" "googleapis" {
  project = google_project.workload.project_id
  name    = "restricted-googleapis"

  dns_name        = "googleapis.com."
  description     = "Resolve supported Google APIs through the restricted.googleapis.com VIP."
  visibility      = "private"
  force_destroy   = false
  deletion_policy = "PREVENT"

  private_visibility_config {
    dynamic "networks" {
      for_each = local.dns_networks

      content {
        network_url = networks.value
      }
    }
  }

  depends_on = [google_project_service.workload["dns.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_dns_record_set" "restricted_googleapis" {
  project      = google_project.workload.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "restricted.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = local.restricted_google_vip_addresses
}

resource "google_dns_record_set" "googleapis_wildcard" {
  project      = google_project.workload.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["restricted.googleapis.com."]
}

resource "google_dns_managed_zone" "private_google_domain" {
  for_each = merge(local.private_google_domains, local.retired_google_domains)

  project = google_project.workload.project_id
  name    = "private-${replace(each.key, "_", "-")}"

  dns_name        = each.value
  description     = "Resolve ${each.value} through the restricted Google API VIP."
  visibility      = "private"
  force_destroy   = false
  deletion_policy = contains(keys(local.retired_google_domains), each.key) ? "DELETE" : "PREVENT"

  private_visibility_config {
    dynamic "networks" {
      for_each = local.dns_networks

      content {
        network_url = networks.value
      }
    }
  }

  depends_on = [google_project_service.workload["dns.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_dns_record_set" "private_google_domain_apex" {
  for_each = local.private_google_domains

  project      = google_project.workload.project_id
  managed_zone = google_dns_managed_zone.private_google_domain[each.key].name
  name         = each.value
  type         = "A"
  ttl          = 300
  rrdatas      = local.restricted_google_vip_addresses
}

resource "google_dns_record_set" "private_google_domain_wildcard" {
  for_each = local.private_google_domains

  project      = google_project.workload.project_id
  managed_zone = google_dns_managed_zone.private_google_domain[each.key].name
  name         = "*.${each.value}"
  type         = "CNAME"
  ttl          = 300
  rrdatas      = [each.value]
}
