resource "google_service_account" "rotation" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  project      = var.runtime.project_id
  account_id   = "agora-json-keys-scheduler"
  display_name = "Agora JSON Keys rotation scheduler"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_cloud_scheduler_job" "rotation" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  depends_on = [google_service_account_iam_member.foundation_rotation]

  project          = var.runtime.project_id
  region           = var.runtime.region
  name             = "agora-json-keys-rotation"
  schedule         = "10 * * * *"
  time_zone        = "Etc/UTC"
  paused           = true
  attempt_deadline = "180s"
  deletion_policy  = "PREVENT"

  # Workflows owns completion; a duplicate delivery must acquire the same service guard.
  retry_config {
    retry_count        = 0
    max_retry_duration = "0s"
  }

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.rotation[0].id}/executions"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode(jsonencode({ disableConcurrencyQuotaOverflowBuffering = true }))

    oauth_token {
      service_account_email = google_service_account.rotation[0].email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  lifecycle {
    prevent_destroy = true
    # Create paused; later foundation convergence must preserve operational pause/resume.
    ignore_changes = [paused]
  }
}

resource "google_service_account_iam_member" "foundation_rotation" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  service_account_id = google_service_account.rotation[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.foundation_service_account}"
}

resource "google_project_iam_custom_role" "rotation_dispatch" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  project     = var.runtime.project_id
  role_id     = "agoraRotationDispatch"
  title       = "Start rotation workflow"
  permissions = ["workflows.executions.create"]
}

resource "google_project_iam_member" "rotation_dispatch" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  # The provider creates an enabled schedule, then pauses it. Grant invocation afterward.
  depends_on = [google_cloud_scheduler_job.rotation]

  # Workflows exposes project-level IAM, so keep this service project to this dispatcher.
  project = var.runtime.project_id
  role    = google_project_iam_custom_role.rotation_dispatch[0].name
  member  = "serviceAccount:${google_service_account.rotation[0].email}"
}
