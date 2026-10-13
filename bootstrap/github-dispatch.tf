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
