locals {
  submitter = "infra-release@${var.project_id}.iam.gserviceaccount.com"
  workers   = { for name in ["deploy", "verify"] : name => google_service_account.execution[name].email }

  # These project-scoped APIs rely on one independently operated service per project.
  project_permissions = {
    submit = [
      "clouddeploy.config.get",
      "clouddeploy.deliveryPipelines.get",
      "clouddeploy.jobRuns.get",
      "clouddeploy.operations.get",
      "clouddeploy.releases.create",
      "clouddeploy.releases.get",
      "clouddeploy.rollouts.create",
      "clouddeploy.rollouts.get",
      "clouddeploy.targets.get",
    ]
    deploy = [
      "clouddeploy.config.get",
      "logging.logEntries.create",
      "run.operations.get",
      "run.revisions.get",
      "run.services.create",
      "run.services.get",
      "run.services.update",
    ]
    verify = [
      "clouddeploy.config.get",
      "clouddeploy.jobRuns.get",
      "clouddeploy.releases.get",
      "clouddeploy.rollouts.get",
      "logging.logEntries.create",
      "run.operations.get",
      "run.revisions.get",
      "run.services.get",
    ]
    probe = ["run.routes.invoke"]
  }
  principals = merge(
    { submit = local.submitter },
    { for name, account in google_service_account.execution : name => account.email },
  )
}

data "google_project" "service" {
  project_id = var.project_id
}

resource "google_service_account" "execution" {
  for_each = toset(["deploy", "verify", "probe"])

  project      = var.project_id
  account_id   = "rollout-${each.key}"
  display_name = "Cloud Deploy ${each.key}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_iam_custom_role" "execution" {
  for_each = local.project_permissions

  project     = var.project_id
  role_id     = "agoraRollout${title(each.key)}"
  title       = "Agora rollout ${each.key}"
  permissions = each.value
}

resource "google_project_iam_member" "execution" {
  for_each = local.project_permissions

  project = var.project_id
  role    = google_project_iam_custom_role.execution[each.key].name
  member  = "serviceAccount:${local.principals[each.key]}"
}

resource "google_service_account_iam_member" "submit_execution" {
  for_each = local.workers

  service_account_id = google_service_account.execution[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.submitter}"
}

resource "google_service_account_iam_member" "deploy_runtime" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.runtime_service_account}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.execution["deploy"].email}"
}

resource "google_project_iam_custom_role" "probe_execution" {
  project     = var.project_id
  role_id     = "agoraRolloutProbeExecution"
  title       = "Execute the private rollout probe"
  permissions = ["run.jobs.get", "run.jobs.run", "run.jobs.runWithOverrides"]
}

resource "google_cloud_run_v2_job_iam_member" "probe_execution" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.probe.name
  role     = google_project_iam_custom_role.probe_execution.name
  member   = "serviceAccount:${google_service_account.execution["verify"].email}"
}

resource "google_artifact_registry_repository_iam_member" "execution" {
  for_each = {
    deploy = "agora-production"
    verify = try(split("/", var.verification_image)[2], "invalid")
  }

  project    = var.project_id
  location   = var.region
  repository = each.value
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${local.workers[each.key]}"
}
