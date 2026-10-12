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

# sys.log reports a post Discord refused.
resource "google_project_iam_member" "downtime_announcer_logs" {
  project = var.management_project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.downtime_announcer.member
}

resource "google_workflows_workflow" "downtime_announcements" {
  name            = "downtime-announcements"
  region          = var.region
  description     = "Posts each step of a planned downtime to Discord at its time."
  service_account = google_service_account.downtime_announcer.id
  source_contents = file("${path.module}/workflows/downtime-announcements.yaml")

  user_env_vars = {
    WEBHOOK_VERSION = tostring(var.downtime_webhook_version)
  }

  # Detailed history and call logs would record the webhook. An execution's own call log level
  # overrides this one, and only downtime.yaml starts executions, without setting it.
  call_log_level          = "LOG_NONE"
  execution_history_level = "EXECUTION_HISTORY_BASIC"
  deletion_protection     = false

  depends_on = [
    google_project_service.management["workflows.googleapis.com"],
    google_secret_manager_secret_iam_member.downtime_announcer,
  ]
}

# downtime.yaml replaces the pending announcements on every change. Only this one workflow lives in
# the management project; Workflows grants no role on a single workflow.
resource "google_project_iam_custom_role" "downtime_dispatcher" {
  role_id     = "infraDowntimeDispatcher"
  title       = "Infra Downtime Dispatcher"
  description = "Start, list and cancel the planned downtime announcement executions."
  stage       = "GA"

  permissions = [
    "workflows.executions.cancel",
    "workflows.executions.create",
    "workflows.executions.get",
    "workflows.executions.list",
    "workflows.workflows.get",
  ]

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_project_iam_member" "downtime_dispatcher" {
  project = var.management_project_id
  role    = google_project_iam_custom_role.downtime_dispatcher.name
  member  = "serviceAccount:${google_service_account.automation["downtime"].email}"
}
