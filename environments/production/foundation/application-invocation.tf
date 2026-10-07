locals {
  application_invocation = merge(
    contains(keys(local.service_release_boundaries), "authentication/private") ? {
      authentication_migrations = { resource = "jobs/agora-authentication-migrations", class = "release" }
    } : {},
    contains(keys(local.service_release_boundaries), "json-keys/private") ? {
      json_keys_migrations = { resource = "jobs/agora-json-keys-migrations", class = "release" }
      json_keys_rotate     = { resource = "jobs/agora-json-keys-rotatekeys", class = "scheduled" }
      json_keys_smoke      = { resource = "jobs/agora-json-keys-smoke", class = "release" }
      json_keys_grpc       = { resource = "services/agora-json-keys-grpc", class = "internal" }
    } : {},
  )
}

resource "google_tags_location_tag_binding" "application" {
  for_each = local.application_invocation

  parent    = "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/${each.value.resource}"
  location  = var.region
  tag_value = google_tags_tag_value.cloud_run_invocation[each.value.class].id
}


resource "google_cloud_scheduler_job" "json_keys_rotation" {
  count = contains(keys(local.application_invocation), "json_keys_rotate") ? 1 : 0

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
    uri         = "https://run.googleapis.com/v2/projects/${var.workload_project_id}/locations/${var.region}/jobs/agora-json-keys-rotatekeys:run"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")

    oauth_token {
      service_account_email = google_service_account.runtime["scheduler_invoker"].email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  lifecycle {
    ignore_changes = [paused]
  }

  depends_on = [google_tags_location_tag_binding.application]
}
