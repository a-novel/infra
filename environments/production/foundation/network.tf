locals {
  network_name = "agora-production"

  network_tags = {
    authentication          = "agora-authentication"
    authentication_database = "agora-database-authentication"
    json_keys_database      = "agora-database-json-keys"
    json_keys               = "agora-json-keys"
    genai_database          = "agora-database-genai"
    genai                   = "agora-genai"
  }

  private_egress_tags = toset(values(local.network_tags))

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
    cloud_run          = "run.app."
    container_registry = "gcr.io."
  }

  # Both networks resolve through the same zones and allowlist until agora-production retires.
  dns_networks = [google_compute_network.production.id, google_compute_network.cluster.id]
}

resource "google_compute_network" "production" {
  project = google_project.workload.project_id
  name    = local.network_name

  auto_create_subnetworks         = false
  delete_default_routes_on_create = true
  mtu                             = 1460
  routing_mode                    = "REGIONAL"
  # The egress allowlist's policy runs first: the classic deny-all would otherwise win.
  network_firewall_policy_enforcement_order = "BEFORE_CLASSIC_FIREWALL"

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_subnetwork" "production" {
  project = google_project.workload.project_id
  region  = var.region
  name    = "${local.network_name}-${var.region}"

  ip_cidr_range            = var.subnet_cidr
  network                  = google_compute_network.production.id
  private_ip_google_access = true
  stack_type               = "IPV4_ONLY"
  lifecycle {
    prevent_destroy = true
  }
}

# The network starts without Google's default routes. These two reach the restricted Google API
# ranges, and internet-egress.tf adds the default route that Cloud NAT needs. IAP TCP forwarding
# uses Google's separate non-removable system route.
resource "google_compute_route" "restricted_google_apis" {
  for_each = local.restricted_google_api_ranges

  project = google_project.workload.project_id
  name    = "restricted-google-${replace(replace(each.value, ".", "-"), "/", "-")}"
  network = google_compute_network.production.id

  dest_range       = each.value
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

resource "google_compute_firewall" "allow_restricted_google_apis" {
  depends_on = [google_project_iam_member.foundation_firewall]

  project = google_project.workload.project_id
  name    = "agora-allow-restricted-google-apis"
  network = google_compute_network.production.name

  direction          = "EGRESS"
  priority           = 800
  destination_ranges = sort(tolist(local.restricted_google_api_ranges))
  target_tags        = sort(tolist(local.private_egress_tags))

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "deny_other_egress" {
  depends_on = [google_project_iam_member.foundation_firewall]

  project = google_project.workload.project_id
  name    = "agora-deny-other-vpc-egress"
  network = google_compute_network.production.name

  direction          = "EGRESS"
  priority           = 1200
  destination_ranges = ["0.0.0.0/0"]

  # Omitting targets makes this the VPC-wide fallback. Otherwise an
  # accidentally untagged endpoint would inherit Google's implied allow egress.
  deny {
    protocol = "all"
  }
}

# Direct VPC egress logs no firewall verdict, so the network logs every lookup instead. The logs
# show the names each workload resolves.
resource "google_dns_policy" "production" {
  project = google_project.workload.project_id
  name    = local.network_name

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
  for_each = local.private_google_domains

  project = google_project.workload.project_id
  name    = "private-${replace(each.key, "_", "-")}"

  dns_name        = each.value
  description     = "Resolve ${each.value} through the restricted Google API VIP."
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
