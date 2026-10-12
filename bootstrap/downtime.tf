# The planned downtime announcements run as Google Cloud Workflows executions, because GitHub
# starts scheduled workflows hours late. This identity runs them: it reads the Discord webhook at
# posting time, so the URL lives only in Secret Manager.
resource "google_service_account" "downtime_announcer" {
  account_id   = "downtime-announcer"
  display_name = "Planned downtime announcer"
  description  = "Runs the downtime-announcements workflow: reads the Discord webhook and posts."
  project      = var.management_project_id

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_secret_manager_secret_iam_member" "downtime_announcer" {
  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application["production-downtime-discord-webhook"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.downtime_announcer.member
}

# Deploying a workflow that runs as this identity requires acting as it.
resource "google_service_account_iam_member" "downtime_announcer_deployer" {
  service_account_id = google_service_account.downtime_announcer.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.automation["foundation"].email}"
}
