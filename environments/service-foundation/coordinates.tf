locals {
  coordinates = merge({
    schema_version = local.coordinates_version
    runtime        = local.runtime
    database       = local.database_coordinates
    rollout        = null
    }, var.zone == null ? {} : { scope = local.scope },
    var.database_handoff == null ? {} : { database = try(jsondecode(var.database_handoff.document_json), null) },
    var.database_handoff == null ? {} : { database_source = var.database_handoff.reference },
  )
  coordinates_json = jsonencode(local.coordinates)
}

resource "google_storage_managed_folder" "coordinates" {
  bucket          = var.state_bucket
  name            = var.zone == null ? "foundation/coordinates/${var.project_id}/" : "foundation/coordinates/${local.scope}/"
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
  member         = "serviceAccount:${local.release_service_account}"
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
    google_project_iam_member.runtime_telemetry,
    google_monitoring_alert_policy.api_error_rate,
    google_cloud_run_v2_service_iam_member.json_keys_invoker,
    google_secret_manager_secret_iam_member.database,
    google_artifact_registry_repository_iam_member.database,
    google_project_iam_member.database_telemetry,
    google_compute_disk_resource_policy_attachment.database,
    module.job_access,
  ]
}

output "coordinates" {
  description = "Pin this exact object and checksum only after the protected apply and convergence succeed."
  value = {
    schema_version = local.coordinates_version
    bucket         = google_storage_bucket_object.coordinates.bucket
    object         = google_storage_bucket_object.coordinates.name
    generation     = google_storage_bucket_object.coordinates.generation
    sha256         = sha256(local.coordinates_json)
  }
}
