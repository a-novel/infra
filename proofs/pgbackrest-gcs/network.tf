resource "google_compute_network" "trial" {
  project                         = var.project_id
  name                            = "pgbackrest-proof"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false
}

resource "google_compute_subnetwork" "trial" {
  project                  = var.project_id
  region                   = "europe-west1"
  name                     = "pgbackrest-proof"
  network                  = google_compute_network.trial.id
  ip_cidr_range            = "10.90.0.0/28"
  private_ip_google_access = true
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_compute_router" "trial" {
  project = var.project_id
  region  = "europe-west1"
  name    = "pgbackrest-proof"
  network = google_compute_network.trial.id
}

resource "google_compute_router_nat" "trial" {
  project                            = var.project_id
  region                             = "europe-west1"
  name                               = "pgbackrest-proof"
  router                             = google_compute_router.trial.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.trial.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "iap" {
  project       = var.project_id
  name          = "pgbackrest-proof-iap"
  network       = google_compute_network.trial.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "https" {
  project            = var.project_id
  name               = "pgbackrest-proof-https"
  network            = google_compute_network.trial.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

resource "google_compute_firewall" "deny_egress" {
  project            = var.project_id
  name               = "pgbackrest-proof-deny-egress"
  network            = google_compute_network.trial.name
  direction          = "EGRESS"
  priority           = 2000
  destination_ranges = ["0.0.0.0/0"]
  deny {
    protocol = "all"
  }
  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
