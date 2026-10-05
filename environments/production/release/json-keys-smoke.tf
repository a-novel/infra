# The service root adopts the existing probe without recreating it.
removed {
  from = google_cloud_run_v2_job.json_keys_smoke
  lifecycle { destroy = false }
}

resource "google_tags_location_tag_binding" "json_keys_smoke" {
  count = var.application_release == null || var.recovery_mode ? 0 : 1

  parent    = "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/jobs/agora-json-keys-smoke"
  location  = var.region
  tag_value = var.cloud_run_invocation_tags.values.release
}
