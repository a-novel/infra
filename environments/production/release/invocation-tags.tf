# Regional bindings make invocation authorization part of the applied resource graph.
resource "google_tags_location_tag_binding" "application" {
  for_each = google_cloud_run_v2_job.application

  parent    = "//run.googleapis.com/projects/${each.value.project}/locations/${each.value.location}/jobs/${each.value.name}"
  location  = each.value.location
  tag_value = var.cloud_run_invocation_tags.values[local.application_jobs[each.key].invocation_class]
}

resource "google_tags_location_tag_binding" "postgres_backup" {
  for_each = google_cloud_run_v2_job.postgres_backup

  parent    = "//run.googleapis.com/projects/${each.value.project}/locations/${each.value.location}/jobs/${each.value.name}"
  location  = each.value.location
  tag_value = var.cloud_run_invocation_tags.values.scheduled
}

resource "google_tags_location_tag_binding" "postgres_restore" {
  for_each = google_cloud_run_v2_job.postgres_restore

  parent    = "//run.googleapis.com/projects/${each.value.project}/locations/${each.value.location}/jobs/${each.value.name}"
  location  = each.value.location
  tag_value = var.cloud_run_invocation_tags.values.scheduled
}

resource "google_tags_location_tag_binding" "postgres_recover" {
  for_each = google_cloud_run_v2_job.postgres_recover

  parent    = "//run.googleapis.com/projects/${each.value.project}/locations/${each.value.location}/jobs/${each.value.name}"
  location  = each.value.location
  tag_value = var.cloud_run_invocation_tags.values.recovery
}

resource "google_tags_location_tag_binding" "postgres_backup_monitor" {
  count = length(google_cloud_run_v2_job.postgres_backup_monitor)

  parent    = "//run.googleapis.com/projects/${google_cloud_run_v2_job.postgres_backup_monitor[count.index].project}/locations/${google_cloud_run_v2_job.postgres_backup_monitor[count.index].location}/jobs/${google_cloud_run_v2_job.postgres_backup_monitor[count.index].name}"
  location  = google_cloud_run_v2_job.postgres_backup_monitor[count.index].location
  tag_value = var.cloud_run_invocation_tags.values.scheduled
}

resource "google_tags_location_tag_binding" "json_keys" {
  count = length(google_cloud_run_v2_service.json_keys)

  parent    = "//run.googleapis.com/projects/${google_cloud_run_v2_service.json_keys[count.index].project}/locations/${google_cloud_run_v2_service.json_keys[count.index].location}/services/${google_cloud_run_v2_service.json_keys[count.index].name}"
  location  = google_cloud_run_v2_service.json_keys[count.index].location
  tag_value = var.cloud_run_invocation_tags.values.internal
}

resource "google_tags_location_tag_binding" "authentication" {
  count = var.recovery_mode ? length(google_cloud_run_v2_service.authentication) : 0

  parent    = "//run.googleapis.com/projects/${google_cloud_run_v2_service.authentication[count.index].project}/locations/${google_cloud_run_v2_service.authentication[count.index].location}/services/${google_cloud_run_v2_service.authentication[count.index].name}"
  location  = google_cloud_run_v2_service.authentication[count.index].location
  tag_value = var.cloud_run_invocation_tags.values.recovery
}
