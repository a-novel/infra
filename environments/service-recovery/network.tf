resource "google_compute_network" "recovery" {
  for_each = local.hosts

  project                         = each.value.project
  name                            = "agora-native-recovery"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = true
}

resource "google_compute_subnetwork" "recovery" {
  for_each = local.hosts

  project                  = each.value.project
  region                   = each.value.region
  name                     = "agora-native-recovery"
  network                  = google_compute_network.recovery[each.key].id
  ip_cidr_range            = "10.91.0.0/28"
  private_ip_google_access = true
}

resource "google_compute_route" "google_apis" {
  for_each = local.hosts

  project          = each.value.project
  name             = "agora-native-recovery-google-apis"
  network          = google_compute_network.recovery[each.key].id
  dest_range       = "199.36.153.4/30"
  next_hop_gateway = "default-internet-gateway"
}

resource "google_compute_firewall" "recovery" {
  for_each = var.recovery == null ? {} : {
    iap         = { direction = "INGRESS", ranges = ["35.235.240.0/20"], port = "22" }
    google-apis = { direction = "EGRESS", ranges = ["199.36.153.4/30"], port = "443" }
  }

  project            = var.recovery.project
  name               = "agora-native-recovery-${each.key}"
  network            = google_compute_network.recovery["selected"].id
  direction          = each.value.direction
  source_ranges      = each.value.direction == "INGRESS" ? each.value.ranges : null
  destination_ranges = each.value.direction == "EGRESS" ? each.value.ranges : null
  allow {
    protocol = "tcp"
    ports    = [each.value.port]
  }
}

resource "google_compute_firewall" "deny_egress" {
  for_each = local.hosts

  project            = each.value.project
  name               = "agora-native-recovery-deny-egress"
  network            = google_compute_network.recovery[each.key].id
  direction          = "EGRESS"
  priority           = 2000
  destination_ranges = ["0.0.0.0/0"]
  deny {
    protocol = "all"
  }
}

resource "google_dns_managed_zone" "apis" {
  for_each = var.recovery == null ? toset([]) : toset(["googleapis.com", "pkg.dev"])

  project    = var.recovery.project
  name       = "recovery-${replace(each.key, ".", "-")}"
  dns_name   = "${each.key}."
  visibility = "private"
  private_visibility_config {
    networks {
      network_url = google_compute_network.recovery["selected"].id
    }
  }
}

resource "google_dns_record_set" "apis" {
  for_each = google_dns_managed_zone.apis

  project      = var.recovery.project
  managed_zone = each.value.name
  name         = "*.${each.key}."
  type         = "A"
  ttl          = 300
  rrdatas      = ["199.36.153.4", "199.36.153.5", "199.36.153.6", "199.36.153.7"]
}
