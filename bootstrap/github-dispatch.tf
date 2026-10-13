# GitHub starts scheduled workflows hours late, so Cloud Scheduler starts the ones that must run on
# time: every hour it runs the github-dispatch workflow, which dispatches each org's stuck bot pull
# request poll (a-novel-kit/.github#298). Each org's dispatch token lives only in Secret Manager.
locals {
  github_dispatch_owners = toset(["a-novel", "a-novel-kit"])
}

# Runs the github-dispatch workflow: reads each org's token at dispatch time.
resource "google_service_account" "github_dispatcher" {
  account_id   = "github-dispatcher"
  display_name = "GitHub workflow dispatcher"
  description  = "Runs the github-dispatch workflow: reads the GitHub dispatch tokens and dispatches."
  project      = var.management_project_id

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_secret_manager_secret_iam_member" "github_dispatcher" {
  for_each = local.github_dispatch_owners

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application["production-github-dispatch-${each.key}"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.github_dispatcher.member
}

# sys.log reports a dispatch GitHub refused.
resource "google_project_iam_member" "github_dispatcher_logs" {
  project = var.management_project_id
  role    = "roles/logging.logWriter"
  member  = google_service_account.github_dispatcher.member
}

# Cloud Scheduler starts the workflow as this identity. Workflows grants no role on a single
# workflow, so it may start any execution in the management project.
resource "google_service_account" "github_dispatch_clock" {
  account_id   = "github-dispatch-clock"
  display_name = "GitHub dispatch clock"
  description  = "Cloud Scheduler's identity: starts the github-dispatch workflow every hour."
  project      = var.management_project_id

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_project_iam_member" "github_dispatch_clock" {
  project = var.management_project_id
  role    = "roles/workflows.invoker"
  member  = google_service_account.github_dispatch_clock.member
}

# Deploying the workflow and the job that run as these identities requires acting as them.
resource "google_service_account_iam_member" "github_dispatch_deployer" {
  for_each = {
    dispatcher = google_service_account.github_dispatcher.name
    clock      = google_service_account.github_dispatch_clock.name
  }

  service_account_id = each.value
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.automation["foundation"].email}"
}

# Google creates the Cloud Scheduler service agent lazily, and it mints the clock's tokens.
resource "google_project_service_identity" "cloudscheduler" {
  provider = google-beta

  project = var.management_project_id
  service = "cloudscheduler.googleapis.com"

  depends_on = [google_project_service.management["cloudscheduler.googleapis.com"]]
}

resource "google_project_iam_member" "cloudscheduler_agent" {
  project = var.management_project_id
  role    = "roles/cloudscheduler.serviceAgent"
  member  = google_project_service_identity.cloudscheduler.member
}

resource "google_workflows_workflow" "github_dispatch" {
  name            = "github-dispatch"
  region          = var.region
  description     = "Dispatches each org's timed .github workflows."
  service_account = google_service_account.github_dispatcher.id
  source_contents = file("${path.module}/workflows/github-dispatch.yaml")

  user_env_vars = {
    DISPATCHES     = jsonencode([for owner in sort(local.github_dispatch_owners) : { owner = owner, workflow = "notify-stuck.yaml" }])
    TOKEN_VERSIONS = jsonencode({ for owner in local.github_dispatch_owners : owner => var.github_dispatch_token_versions[owner] })
  }

  # Detailed history and call logs would record the tokens. Only the clock starts executions, without
  # overriding these.
  call_log_level          = "LOG_NONE"
  execution_history_level = "EXECUTION_HISTORY_BASIC"
  deletion_protection     = false

  depends_on = [
    google_project_iam_member.workflows_agent,
    google_secret_manager_secret_iam_member.github_dispatcher,
  ]
}

resource "google_cloud_scheduler_job" "github_dispatch" {
  project          = var.management_project_id
  region           = var.region
  name             = "github-dispatch"
  description      = "Starts the github-dispatch workflow every hour."
  schedule         = "17 * * * *"
  time_zone        = "Etc/UTC"
  attempt_deadline = "180s"

  retry_config {
    retry_count          = 1
    min_backoff_duration = "30s"
    max_backoff_duration = "60s"
  }

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.github_dispatch.id}/executions"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")

    oauth_token {
      service_account_email = google_service_account.github_dispatch_clock.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_iam_member.cloudscheduler_agent,
    google_project_iam_member.github_dispatch_clock,
  ]
}
