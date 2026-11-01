locals {
  # Resource names use "api" for the public-api zone.
  name = "agora-${var.service}-${var.zone == "public-api" ? "api" : var.zone}"
}

resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = local.name
  display_name = "A-Novel ${var.service} application"

  lifecycle {
    prevent_destroy = true
  }
}

# The deploy identity attaches this account to Cloud Run services and jobs.
resource "google_service_account_iam_member" "deployer" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.deployer}"
}

resource "google_secret_manager_secret_iam_member" "runtime" {
  for_each = var.secrets

  project   = var.management_project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.runtime.member
}

# The main server runs as the runtime identity. Every other workload runs as its own, so a job
# reads only the secrets it mounts and a compromised image reaches nothing else.
resource "google_service_account" "workload" {
  for_each = var.workloads

  project      = var.project_id
  account_id   = "agora-${var.service}-${each.key}"
  display_name = "A-Novel ${var.service} ${each.key}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account_iam_member" "workload_deployer" {
  for_each = var.workloads

  service_account_id = google_service_account.workload[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.deployer}"
}

resource "google_secret_manager_secret_iam_member" "workload" {
  for_each = merge([for role, workload in var.workloads : {
    for secret in workload.secrets : "${role}:${secret}" => { role = role, secret = secret }
  }]...)

  project   = var.management_project_id
  secret_id = each.value.secret
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.workload[each.value.role].member
}

# The cluster runs every release from the private production repository. The others retire with the
# old platform (a-novel/infra#1208).
resource "google_artifact_registry_repository" "images" {
  for_each = toset(["production", "tooling"])

  project         = var.project_id
  location        = var.region
  repository_id   = "${local.name}-${each.key}"
  format          = "DOCKER"
  mode            = "STANDARD_REPOSITORY"
  deletion_policy = var.zone == "private" && each.key == "production" ? "PREVENT" : "DELETE"
  labels          = { environment = "production", service = var.service }

  # A deployed digest can never be re-tagged to different content.
  docker_config {
    immutable_tags = true
  }

  cleanup_policy_dry_run = true

  lifecycle {
    prevent_destroy = true
  }
}

# The database host pulls PostgreSQL from the production repository and, with native backups, its
# TLS loader from tooling. It reads no other service's images.
resource "google_artifact_registry_repository_iam_member" "database" {
  for_each = toset(var.database_service_account == null ? [] : keys(google_artifact_registry_repository.images))

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.images[each.key].repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.database_service_account}"
}

resource "google_monitoring_notification_channel" "operations" {
  project         = var.project_id
  display_name    = "A-Novel ${var.service} production operations alerts"
  type            = "email"
  enabled         = true
  labels          = { email_address = var.alert_email }
  deletion_policy = "DELETE"
  force_delete    = false

  lifecycle {
    prevent_destroy = true
  }
}
