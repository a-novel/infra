provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  foundation_service_account = "infra-foundation@${var.management_project_id}.iam.gserviceaccount.com"
  zone_suffix                = var.zone == "public-api" ? "api" : var.zone
  release_service_account    = var.zone == null ? "infra-release@${var.project_id}.iam.gserviceaccount.com" : "infra-${var.service}-${local.zone_suffix}@${var.project_id}.iam.gserviceaccount.com"
  coordinates_version        = var.zone == null ? 1 : 2
  scope                      = var.zone == null ? "services/${var.project_id}" : "workloads/production/${var.zone}/${var.project_id}/${var.service}"
  runtime_secrets = {
    json-keys = toset(concat(
      ["production-json-keys-postgres-password"],
      var.zone == "public-api" ? [] : ["production-json-keys-app-master-key"],
    ))
    authentication = toset(concat(
      ["production-authentication-postgres-password"],
      var.zone == "private" ? [] : ["production-authentication-smtp-sender-password"],
    ))
  }
  job_secrets = {
    json-keys      = local.runtime_secrets.json-keys
    authentication = toset(["production-authentication-postgres-password"])
  }
}

resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = var.zone == null ? "agora-${var.service}" : "agora-${var.service}-${local.zone_suffix}"
  display_name = "Agora ${var.service} application"

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = terraform.workspace == "default"
      error_message = "Service foundation owns one default-workspace state per authorized service scope."
    }
    precondition {
      condition = var.zone == null || (
        var.database == null && var.pgbackrest_repository == null && var.database_runtime == null &&
        !var.manage_job_access
      )
      error_message = "Shared-zone prerequisites cannot enroll hosts or application jobs before their ownership handoff."
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "json_keys_invoker" {
  count = var.database_handoff != null && (
    (var.zone == "public-api" && var.service == "authentication") ||
    (var.zone == "private" && var.service == "json-keys")
  ) ? 1 : 0

  project  = var.database_handoff.private_project_id
  location = var.region
  name     = "agora-json-keys-grpc"
  role     = "roles/run.servicesInvoker"
  member   = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_service_account_iam_member" "foundation_runtime" {
  service_account_id = google_service_account.runtime.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.foundation_service_account}"
}

resource "google_project_iam_member" "runtime_telemetry" {
  for_each = toset(["roles/telemetry.writer", "roles/serviceusage.serviceUsageConsumer"])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

# Payloads and numeric version selection belong to the operator and release contract.
resource "google_secret_manager_secret_iam_member" "runtime" {
  for_each = lookup(local.runtime_secrets, var.service, toset([]))

  project   = var.management_project_id
  secret_id = each.key
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "foundation_job_metadata" {
  for_each = var.zone == "public-api" ? lookup(local.runtime_secrets, var.service, toset([])) : var.zone == null ? lookup(local.job_secrets, var.service, toset([])) : toset([])

  project   = var.management_project_id
  secret_id = each.key
  role      = "roles/secretmanager.viewer"
  member    = "serviceAccount:${local.foundation_service_account}"
}

resource "google_artifact_registry_repository" "images" {
  for_each = toset(["agora-production", "agora-tooling"])

  project         = var.project_id
  location        = var.region
  repository_id   = var.zone == null ? each.key : "agora-${var.service}-${local.zone_suffix}-${trimprefix(each.key, "agora-")}"
  format          = "DOCKER"
  mode            = "STANDARD_REPOSITORY"
  deletion_policy = "PREVENT"
  labels          = { environment = "production", service = var.service }

  docker_config {
    immutable_tags = true
  }

  # Retained recovery receipts may reference any stored digest.
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
  member     = "serviceAccount:${local.release_service_account}"
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
