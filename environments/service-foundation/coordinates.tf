locals {
  coordinates = {
    schema_version = 1
    runtime        = local.runtime
    database       = local.database_coordinates
    rollout        = try(module.rollout["api"].rollout, null)
  }
  coordinates_json = jsonencode(local.coordinates)
}

resource "google_storage_managed_folder" "coordinates" {
  bucket          = var.state_bucket
  name            = "foundation/coordinates/${var.project_id}/"
  force_destroy   = false
  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_managed_folder_iam_member" "coordinate_reader" {
  bucket         = google_storage_managed_folder.coordinates.bucket
  managed_folder = google_storage_managed_folder.coordinates.name
  role           = "roles/storage.objectViewer"
  member         = "serviceAccount:infra-release@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_storage_bucket_object" "coordinates" {
  bucket          = google_storage_managed_folder.coordinates.bucket
  name            = "${google_storage_managed_folder.coordinates.name}${sha256(local.coordinates_json)}.json"
  content         = local.coordinates_json
  content_type    = "application/json"
  cache_control   = "private, no-store"
  deletion_policy = "ABANDON"

  # Retained references outlive this root's current snapshot. Publication is
  # configuration evidence; only a successful protected run can approve its use.
  depends_on = [
    google_storage_managed_folder_iam_member.coordinate_reader,
    google_secret_manager_secret_iam_member.runtime,
    google_secret_manager_secret_iam_member.foundation_job_metadata,
    google_artifact_registry_repository_iam_member.release,
    google_artifact_registry_repository_iam_member.recovery,
    google_service_account_iam_member.foundation_runtime,
    google_secret_manager_secret_iam_member.database,
    google_artifact_registry_repository_iam_member.database,
    google_project_iam_member.database_telemetry,
    google_compute_disk_resource_policy_attachment.database,
    module.rollout,
    module.job_access,
  ]
}

output "coordinates" {
  description = "Pin this exact object and checksum only after the protected apply and convergence succeed."
  value = {
    schema_version = 1
    bucket         = google_storage_bucket_object.coordinates.bucket
    object         = google_storage_bucket_object.coordinates.name
    generation     = google_storage_bucket_object.coordinates.generation
    sha256         = sha256(local.coordinates_json)
  }
}
