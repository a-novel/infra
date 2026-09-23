provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  foundation_service_account = "infra-foundation@${var.management_project_id}.iam.gserviceaccount.com"
  runtime_secrets = {
    json-keys      = toset(["production-json-keys-postgres-password", "production-json-keys-app-master-key"])
    authentication = toset(["production-authentication-postgres-password", "production-authentication-smtp-sender-password"])
  }
}

resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = "agora-${var.service}"
  display_name = "Agora ${var.service} application"

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = terraform.workspace == "default"
      error_message = "Service foundation owns one default-workspace state per project."
    }
  }
}

resource "google_service_account_iam_member" "foundation_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.foundation_service_account}"
}

# Payloads and numeric version selection belong to the operator and release contract.
resource "google_secret_manager_secret_iam_member" "runtime" {
  for_each = lookup(local.runtime_secrets, var.service, toset([]))

  project   = var.management_project_id
  secret_id = each.key
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_artifact_registry_repository" "images" {
  for_each = toset(["agora-production", "agora-tooling"])

  project         = var.project_id
  location        = var.region
  repository_id   = each.key
  format          = "DOCKER"
  mode            = "STANDARD_REPOSITORY"
  deletion_policy = "PREVENT"
  labels          = { environment = "production", service = var.service }

  docker_config {
    immutable_tags = true
  }

  # Retained receipts and Cloud Deploy releases may reference any stored digest.
  cleanup_policy_dry_run = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_artifact_registry_repository_iam_member" "release" {
  project    = var.project_id
  location   = google_artifact_registry_repository.images["agora-production"].location
  repository = google_artifact_registry_repository.images["agora-production"].repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:infra-release@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_artifact_registry_repository_iam_member" "recovery" {
  for_each = google_artifact_registry_repository.images

  project    = var.project_id
  location   = each.value.location
  repository = each.value.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:infra-recovery@${var.management_project_id}.iam.gserviceaccount.com"
}

resource "google_monitoring_notification_channel" "operations" {
  project         = var.project_id
  display_name    = "Agora ${var.service} production operations alerts"
  type            = "email"
  enabled         = true
  labels          = { email_address = var.operations_alert_email }
  deletion_policy = "PREVENT"
  force_delete    = false

  lifecycle {
    prevent_destroy = true
  }
}
