locals {
  # Resource names use "api" for the public-api zone.
  name = "agora-${var.service}-${var.zone == "public-api" ? "api" : var.zone}"
}

resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = local.name
  display_name = "Agora ${var.service} application"

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

resource "google_project_iam_member" "telemetry" {
  for_each = toset(["roles/telemetry.writer", "roles/serviceusage.serviceUsageConsumer"])

  project = var.project_id
  role    = each.value
  member  = google_service_account.runtime.member
}

resource "google_secret_manager_secret_iam_member" "runtime" {
  for_each = var.secrets

  project   = var.management_project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.runtime.member
}

resource "google_artifact_registry_repository" "images" {
  for_each = toset(["production", "tooling"])

  project         = var.project_id
  location        = var.region
  repository_id   = "${local.name}-${each.key}"
  format          = "DOCKER"
  mode            = "STANDARD_REPOSITORY"
  deletion_policy = "PREVENT"
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

resource "google_monitoring_notification_channel" "operations" {
  project         = var.project_id
  display_name    = "Agora ${var.service} production operations alerts"
  type            = "email"
  enabled         = true
  labels          = { email_address = var.alert_email }
  deletion_policy = "PREVENT"
  force_delete    = false

  lifecycle {
    prevent_destroy = true
  }
}
