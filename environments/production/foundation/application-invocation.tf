locals {
  application_invocation = merge(
    contains(keys(local.service_release_boundaries), "authentication/private") ? {
      authentication_migrations  = { resource = "jobs/agora-authentication-migrations", class = "release" }
      authentication_maintenance = { resource = "jobs/agora-authentication-maintenance", class = "maintenance" }
    } : {},
    contains(keys(local.service_release_boundaries), "json-keys/private") ? {
      json_keys_migrations = { resource = "jobs/agora-json-keys-migrations", class = "release" }
      json_keys_rotate     = { resource = "jobs/agora-json-keys-rotatekeys", class = "scheduled" }
      json_keys_smoke      = { resource = "jobs/agora-json-keys-smoke", class = "release" }
      json_keys_grpc       = { resource = "services/agora-json-keys-grpc", class = "internal" }
    } : {},
    contains(keys(local.service_release_boundaries), "genai/private") ? {
      genai_migrations = { resource = "jobs/agora-genai-migrations", class = "release" }
      genai_smoke      = { resource = "jobs/agora-genai-smoke", class = "release" }
      genai_grpc       = { resource = "services/agora-genai-grpc", class = "internal" }
      genai_sweep      = { resource = "services/agora-genai-sweep", class = "internal" }
    } : {},
  )
  # The service's deterministic URL, which foundation knows before reading the service root.
  genai_sweep_url = "https://agora-genai-sweep-${google_project.workload.number}.${var.region}.run.app"
}

resource "google_tags_location_tag_binding" "application" {
  for_each = local.application_invocation

  parent    = "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/${each.value.resource}"
  location  = var.region
  tag_value = google_tags_tag_value.cloud_run_invocation[each.value.class].id

  # The provisioning role stays out of depends_on. OpenTofu replaces a dependent before it updates
  # what the dependent depends on, so a replacement never uses a permission from the same change.
  depends_on = [google_tags_tag_value_iam_member.foundation_application_tags]
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

# Foundation may set invokers only on a service tagged internal, so the grant waits for the tag.
resource "google_cloud_run_v2_service_iam_member" "genai_sweep_scheduler" {
  count = contains(keys(local.application_invocation), "genai_sweep") ? 1 : 0

  project  = var.workload_project_id
  location = var.region
  name     = "agora-genai-sweep"
  role     = "roles/run.servicesInvoker"
  member   = "serviceAccount:${google_service_account.runtime["scheduler_invoker"].email}"

  depends_on = [google_tags_location_tag_binding.application]
}

# The sweep checks the generations nobody polled, so a generation settles while the provider still
# holds its result. A call that fails is not retried: the next minute's call takes over.
resource "google_cloud_scheduler_job" "genai_sweep" {
  count = contains(keys(local.application_invocation), "genai_sweep") ? 1 : 0

  project          = var.workload_project_id
  region           = var.region
  name             = "agora-genai-sweep"
  schedule         = "* * * * *"
  time_zone        = "Etc/UTC"
  paused           = false
  attempt_deadline = "180s"

  retry_config {
    retry_count = 0
  }

  http_target {
    http_method = "POST"
    uri         = "${local.genai_sweep_url}/sweep"

    oidc_token {
      service_account_email = google_service_account.runtime["scheduler_invoker"].email
      audience              = local.genai_sweep_url
    }
  }

  lifecycle {
    ignore_changes = [paused]
  }

  depends_on = [google_cloud_run_v2_service_iam_member.genai_sweep_scheduler]
}
