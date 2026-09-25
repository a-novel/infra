resource "google_service_account" "rotation" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  project      = var.runtime.project_id
  account_id   = "agora-json-keys-scheduler"
  display_name = "Agora JSON Keys rotation invoker"

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

  # RunJob acknowledges dispatch, before rotation completes. Do not retry that request.
  retry_config {
    retry_count        = 0
    max_retry_duration = "0s"
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.runtime.project_id}/locations/${var.runtime.region}/jobs/agora-json-keys-rotatekeys:run"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")

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

resource "google_cloud_run_v2_job_iam_member" "rotation" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  # The provider creates an enabled schedule, then pauses it. Grant invocation afterward.
  depends_on = [google_cloud_scheduler_job.rotation]

  project  = var.runtime.project_id
  location = var.runtime.region
  name     = "agora-json-keys-rotatekeys"
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.rotation[0].email}"
}
