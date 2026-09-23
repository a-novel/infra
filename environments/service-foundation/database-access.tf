data "google_project" "database" {
  for_each   = local.database
  project_id = var.project_id
}

resource "google_service_account" "database" {
  for_each = local.database

  project      = var.project_id
  account_id   = "agora-database"
  display_name = "Agora ${var.service} PostgreSQL host"
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account_iam_member" "database_attachment" {
  for_each = var.database == null ? {} : {
    foundation = local.foundation_service_account
    mig        = "${data.google_project.database["host"].number}@cloudservices.gserviceaccount.com"
  }
  service_account_id = google_service_account.database["host"].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${each.value}"
}

resource "google_project_iam_member" "database_telemetry" {
  for_each = var.database == null ? toset([]) : toset([
    "roles/logging.logWriter", "roles/monitoring.metricWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.database["host"].email}"
}

resource "google_secret_manager_secret_iam_member" "database" {
  for_each = var.database == null ? toset([]) : toset([
    "production-${var.service}-postgres-password", "production-${var.service}-postgres-backup-password",
  ])
  project   = var.management_project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.database["host"].email}"
}

resource "google_artifact_registry_repository_iam_member" "database" {
  for_each = local.database

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.images["agora-production"].repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.database[each.key].email}"
}
