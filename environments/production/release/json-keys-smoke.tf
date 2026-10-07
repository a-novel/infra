resource "google_tags_location_tag_binding" "json_keys_smoke" {
  count = 1

  parent    = "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/jobs/agora-json-keys-smoke"
  location  = var.region
  tag_value = var.cloud_run_invocation_tags.values.release
}
