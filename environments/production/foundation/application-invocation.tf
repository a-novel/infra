variable "manage_application_invocation" {
  description = "Adopt the existing private application invocation tags and rotation schedule after their release-root ownership is removed."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition = !var.manage_application_invocation || (
      !var.recovery_mode && alltrue([for service in ["authentication", "json-keys"] :
        contains(lookup(var.service_release_zones, service, toset([])), "private")
      ])
    )
    error_message = "Application invocation adoption requires both private service release boundaries outside recovery mode."
  }
}

variable "import_application_invocation" {
  description = "Import the six existing objects during their one-time state handoff; disable for mock-provider tests."
  type        = bool
  default     = true
  nullable    = false
}

locals {
  application_invocation = var.manage_application_invocation ? {
    authentication_migrations = { resource = "jobs/agora-authentication-migrations", class = "release" }
    json_keys_migrations      = { resource = "jobs/agora-json-keys-migrations", class = "release" }
    json_keys_rotate          = { resource = "jobs/agora-json-keys-rotatekeys", class = "scheduled" }
    json_keys_smoke           = { resource = "jobs/agora-json-keys-smoke", class = "release" }
    json_keys_grpc            = { resource = "services/agora-json-keys-grpc", class = "internal" }
  } : {}
}

resource "google_tags_location_tag_binding" "application" {
  for_each = local.application_invocation

  parent    = "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/${each.value.resource}"
  location  = var.region
  tag_value = google_tags_tag_value.cloud_run_invocation[each.value.class].id
}

import {
  for_each = var.import_application_invocation ? local.application_invocation : {}
  to       = google_tags_location_tag_binding.application[each.key]
  id       = "${var.region}/tagBindings/${urlencode("//run.googleapis.com/projects/${google_project.workload.number}/locations/${var.region}/${each.value.resource}")}/${google_tags_tag_value.cloud_run_invocation[each.value.class].id}"
}

resource "google_cloud_scheduler_job" "json_keys_rotation" {
  count = var.manage_application_invocation ? 1 : 0

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

import {
  for_each = var.manage_application_invocation && var.import_application_invocation ? toset(["rotation"]) : toset([])
  to       = google_cloud_scheduler_job.json_keys_rotation[0]
  id       = "projects/${var.workload_project_id}/locations/${var.region}/jobs/agora-json-keys-rotation"
}
