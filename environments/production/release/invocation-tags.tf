resource "google_tags_location_tag_binding" "application" {
  for_each = local.application_jobs

  parent    = "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/jobs/${each.value.name}"
  location  = var.region
  tag_value = var.cloud_run_invocation_tags.values[each.value.invocation_class]
}

resource "google_tags_location_tag_binding" "json_keys" {
  count = 1

  parent    = "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/services/agora-json-keys-grpc"
  location  = var.region
  tag_value = var.cloud_run_invocation_tags.values.internal
}
