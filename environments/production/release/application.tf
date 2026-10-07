# Runtime definitions belong to the service roots. This root owns only their
# existing invocation tags and the hourly idempotent key-rotation schedule.
resource "google_cloud_scheduler_job" "json_keys_rotation" {
  depends_on = [google_tags_location_tag_binding.application]
  count      = 1

  project          = var.workload_project_id
  region           = var.region
  name             = "agora-json-keys-rotation"
  schedule         = "10 * * * *"
  time_zone        = "Etc/UTC"
  paused           = false
  attempt_deadline = "180s"

  retry_config {
    retry_count          = 1
    min_backoff_duration = "30s"
    max_backoff_duration = "60s"
    max_doublings        = 5
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.workload_project_id}/locations/${var.region}/jobs/${local.application_jobs["json_keys_rotate"].name}:run"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")

    oauth_token {
      service_account_email = var.runtime_service_accounts.scheduler_invoker
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  lifecycle {
    ignore_changes = [paused]
  }
}
