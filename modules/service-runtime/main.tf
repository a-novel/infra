locals {
  name = "agora-${var.service}-private"
}

# The cluster runs every release from the production repository. Tooling retires with the database
# hosts (a-novel/infra#1208).
resource "google_artifact_registry_repository" "images" {
  for_each = toset(["production", "tooling"])

  project         = var.project_id
  location        = var.region
  repository_id   = "${local.name}-${each.key}"
  format          = "DOCKER"
  mode            = "STANDARD_REPOSITORY"
  deletion_policy = each.key == "production" ? "PREVENT" : "DELETE"
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
