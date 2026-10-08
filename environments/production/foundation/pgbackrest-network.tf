variable "pgbackrest_repository_services" {
  description = "Services whose backup repository host gets database network access."
  type        = set(string)
  default     = []
  nullable    = false

  validation {
    condition     = length(setsubtract(var.pgbackrest_repository_services, ["json-keys", "authentication"])) == 0
    error_message = "Select supported database services for repository networking."
  }

  validation {
    condition = length(setsubtract(var.pgbackrest_repository_services,
      toset([for service, zones in var.service_release_zones : service if try(contains(zones, "private"), false)]),
    )) == 0
    error_message = "Repository networking requires a registered private service."
  }
}

locals {
  pgbackrest_network = merge({}, {
    for service, zones in var.service_release_zones : service => {
      database   = google_service_account.runtime["${replace(service, "-", "_")}_database"].email
      repository = "agora-pgbr-${service}@${var.workload_project_id}.iam.gserviceaccount.com"
    } if try(contains(zones, "private"), false) && contains(var.pgbackrest_repository_services, service)
  })
}

resource "google_compute_firewall" "pgbackrest_database_egress" {
  for_each = local.pgbackrest_network

  project = google_project.workload.project_id
  name    = "agora-${each.key}-repository-egress"
  network = google_compute_network.production.name

  direction               = "EGRESS"
  priority                = 810
  target_service_accounts = [each.value.database]
  destination_ranges      = [var.subnet_cidr]

  # Classic egress rules cannot select a destination identity. The matching
  # ingress rule below restricts the receiving repository to its own database.
  allow {
    protocol = "tcp"
    ports    = ["8432"]
  }

  depends_on = [google_project_iam_member.foundation_firewall]
}

resource "google_compute_firewall" "pgbackrest_repository_ingress" {
  for_each = local.pgbackrest_network

  project = google_project.workload.project_id
  name    = "agora-${each.key}-repository-ingress"
  network = google_compute_network.production.name

  direction               = "INGRESS"
  priority                = 810
  target_service_accounts = [each.value.repository]
  # Adding source_ranges would permit identity OR range, not their intersection.
  source_service_accounts = [each.value.database]

  allow {
    protocol = "tcp"
    ports    = ["8432"]
  }

  depends_on = [google_project_iam_member.foundation_firewall]
}

resource "google_compute_firewall" "pgbackrest_google_egress" {
  for_each = local.pgbackrest_network

  project = google_project.workload.project_id
  name    = "agora-${each.key}-repository-google-apis"
  network = google_compute_network.production.name

  direction               = "EGRESS"
  priority                = 810
  target_service_accounts = [each.value.repository]
  destination_ranges      = sort(tolist(local.restricted_google_api_ranges))

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  depends_on = [google_project_iam_member.foundation_firewall]
}

resource "google_compute_firewall" "pgbackrest_iap_ingress" {
  for_each = local.pgbackrest_network

  project = google_project.workload.project_id
  name    = "agora-${each.key}-repository-iap"
  network = google_compute_network.production.name

  direction               = "INGRESS"
  priority                = 810
  target_service_accounts = [each.value.repository]
  source_ranges           = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  depends_on = [google_project_iam_member.foundation_firewall]
}
