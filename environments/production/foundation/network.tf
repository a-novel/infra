locals {
  network_name = "agora-production"

  network_tags = {
    authentication = "agora-authentication"
    backup         = "agora-backup"
    database       = "agora-database"
    json_keys      = "agora-json-keys"
    restore        = "agora-restore"
  }

  database_caller_tags = toset([
    local.network_tags.authentication,
    local.network_tags.backup,
    local.network_tags.json_keys,
    local.network_tags.restore,
  ])

  private_egress_tags = toset(values(local.network_tags))

  private_google_api_ranges = toset([
    "199.36.153.8/30",
    "34.126.0.0/18",
  ])

  private_google_vip_addresses = [
    "199.36.153.8",
    "199.36.153.9",
    "199.36.153.10",
    "199.36.153.11",
  ]

  private_google_domains = {
    artifact_registry = "pkg.dev."
    cloud_run         = "run.app."
  }
}

resource "google_compute_network" "production" {
  project = google_project.workload.project_id
  name    = local.network_name

  auto_create_subnetworks         = false
  delete_default_routes_on_create = true
  mtu                             = 1460
  routing_mode                    = "REGIONAL"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
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

# Deleting the catch-all route removes an accidental public path. These two
# explicit routes retain only Private Google Access and direct Google API paths.
resource "google_compute_route" "private_google_apis" {
  for_each = local.private_google_api_ranges

  project = google_project.workload.project_id
  name    = "private-google-${replace(replace(each.value, ".", "-"), "/", "-")}"
  network = google_compute_network.production.id

  dest_range       = each.value
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

resource "google_compute_firewall" "allow_private_google_apis" {
  project = google_project.workload.project_id
  name    = "agora-allow-private-google-apis"
  network = google_compute_network.production.name

  direction          = "EGRESS"
  priority           = 800
  destination_ranges = sort(tolist(local.private_google_api_ranges))
  target_tags        = sort(tolist(local.private_egress_tags))

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "allow_postgres_egress" {
  project = google_project.workload.project_id
  name    = "agora-allow-postgres-egress"
  network = google_compute_network.production.name

  direction          = "EGRESS"
  priority           = 810
  destination_ranges = [var.subnet_cidr]
  target_tags        = sort(tolist(local.database_caller_tags))

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
}

resource "google_compute_firewall" "deny_other_egress" {
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

resource "google_compute_firewall" "allow_postgres_ingress" {
  project = google_project.workload.project_id
  name    = "agora-allow-postgres-ingress"
  network = google_compute_network.production.name

  direction     = "INGRESS"
  priority      = 800
  source_ranges = [var.subnet_cidr]
  target_tags   = [local.network_tags.database]

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }
}

resource "google_compute_firewall" "allow_iap_ssh" {
  project = google_project.workload.project_id
  name    = "agora-allow-iap-ssh"
  network = google_compute_network.production.name

  direction     = "INGRESS"
  priority      = 810
  source_ranges = ["35.235.240.0/20"]
  target_tags   = [local.network_tags.database]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_dns_managed_zone" "googleapis" {
  project = google_project.workload.project_id
  name    = "private-googleapis"

  dns_name        = "googleapis.com."
  description     = "Resolve Google APIs through the private.googleapis.com VIP."
  visibility      = "private"
  force_destroy   = false
  deletion_policy = "PREVENT"

  private_visibility_config {
    networks {
      network_url = google_compute_network.production.id
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["dns.googleapis.com"]]
}

resource "google_dns_record_set" "private_googleapis" {
  project      = google_project.workload.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "private.googleapis.com."
  type         = "A"
  ttl          = 300
  rrdatas      = local.private_google_vip_addresses
}

resource "google_dns_record_set" "googleapis_wildcard" {
  project      = google_project.workload.project_id
  managed_zone = google_dns_managed_zone.googleapis.name
  name         = "*.googleapis.com."
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["private.googleapis.com."]
}

resource "google_dns_managed_zone" "private_google_domain" {
  for_each = local.private_google_domains

  project = google_project.workload.project_id
  name    = "private-${replace(each.key, "_", "-")}"

  dns_name        = each.value
  description     = "Resolve ${each.value} through the private Google API VIP."
  visibility      = "private"
  force_destroy   = false
  deletion_policy = "PREVENT"

  private_visibility_config {
    networks {
      network_url = google_compute_network.production.id
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["dns.googleapis.com"]]
}

resource "google_dns_record_set" "private_google_domain_apex" {
  for_each = local.private_google_domains

  project      = google_project.workload.project_id
  managed_zone = google_dns_managed_zone.private_google_domain[each.key].name
  name         = each.value
  type         = "A"
  ttl          = 300
  rrdatas      = local.private_google_vip_addresses
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
