variable "pgbackrest_repository_services" {
  description = "Opt-in native repository network for registered private services or dedicated service projects. Empty by default and ignored during recovery."
  type        = set(string)
  default     = []
  nullable    = false

  validation {
    condition     = length(setsubtract(var.pgbackrest_repository_services, ["json-keys"])) == 0
    error_message = "Only the JSON Keys repository pilot is supported."
  }

  validation {
    condition = var.recovery_mode || length(setsubtract(var.pgbackrest_repository_services, setunion(
      toset(keys(var.service_projects)),
      toset([for service, zones in var.service_release_zones : service if try(contains(zones, "private"), false)]),
    ))) == 0
    error_message = "Repository networking requires a registered private service or dedicated service project."
  }
}

locals {
  # Recovery compiles a copy of production inputs with no service projects.
  pgbackrest_network = var.recovery_mode ? {} : merge({
    for service, project in var.service_projects : service => {
      database   = "agora-database@${project}.iam.gserviceaccount.com"
      repository = "agora-backup-repository@${project}.iam.gserviceaccount.com"
    } if contains(var.pgbackrest_repository_services, service)
    }, {
    for service, zones in var.service_release_zones : service => {
      database   = "agora-${service}-database@${var.workload_project_id}.iam.gserviceaccount.com"
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

  depends_on = [google_project_iam_member.foundation_firewall, google_compute_shared_vpc_service_project.service]
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

  depends_on = [google_project_iam_member.foundation_firewall, google_compute_shared_vpc_service_project.service]
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

  depends_on = [google_project_iam_member.foundation_firewall, google_compute_shared_vpc_service_project.service]
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

  depends_on = [google_project_iam_member.foundation_firewall, google_compute_shared_vpc_service_project.service]
}
