locals {
  zone_suffix      = try(var.scope.zone == "public-api" ? "api" : var.scope.zone, null)
  identity_suffix  = var.scope == null ? "" : "-${var.scope.service}-${local.zone_suffix}"
  role_suffix      = replace(local.identity_suffix, "-", "_")
  submitter        = "infra${var.scope == null ? "-release" : local.identity_suffix}@${var.project_id}.iam.gserviceaccount.com"
  workers          = { for name in ["deploy", "verify"] : name => google_service_account.execution[name].email }
  image_repository = var.scope == null ? "agora-production" : "agora${local.identity_suffix}-production"
  source_folder    = var.scope == null ? "services/${var.project_id}/production/sources/" : "workloads/production/${var.scope.zone}/${var.project_id}/${var.scope.service}/production/sources/"

  # These APIs have no service/pipeline IAM parent. Their metadata is not tenant-private.
  project_permissions = {
    submit = [
      "clouddeploy.config.get",
      "clouddeploy.operations.get",
    ]
    deploy = [
      "clouddeploy.config.get",
      "logging.logEntries.create",
      "run.operations.get",
    ]
    verify = [
      "clouddeploy.config.get",
      "logging.logEntries.create",
      "run.operations.get",
    ]
  }
  pipeline_permissions = {
    submit = [
      "clouddeploy.deliveryPipelines.get", "clouddeploy.jobRuns.get",
      "clouddeploy.releases.create", "clouddeploy.releases.get",
      "clouddeploy.rollouts.create", "clouddeploy.rollouts.get",
    ]
    verify = ["clouddeploy.jobRuns.get", "clouddeploy.releases.get", "clouddeploy.rollouts.get"]
  }
  service_permissions = {
    submit = ["run.services.get"]
    deploy = ["run.revisions.get", "run.services.get", "run.services.update"]
    verify = ["run.revisions.get", "run.services.get"]
    probe  = ["run.routes.invoke"]
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
  account_id   = var.scope == null ? "rollout-${each.key}" : "${each.key}${local.identity_suffix}"
  display_name = "Cloud Deploy ${each.key}"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_iam_custom_role" "execution" {
  for_each = local.project_permissions

  project     = var.project_id
  role_id     = "agoraRollout${title(each.key)}${local.role_suffix}"
  title       = "Agora rollout ${each.key}"
  permissions = each.value
}

resource "google_project_iam_member" "execution" {
  for_each = local.project_permissions

  project = var.project_id
  role    = google_project_iam_custom_role.execution[each.key].name
  member  = "serviceAccount:${local.principals[each.key]}"
}

resource "google_project_iam_custom_role" "pipeline" {
  for_each = local.pipeline_permissions

  project     = var.project_id
  role_id     = "agoraPipeline${title(each.key)}${local.role_suffix}"
  title       = "Agora pipeline ${each.key}"
  permissions = each.value
}

resource "google_clouddeploy_delivery_pipeline_iam_member" "execution" {
  for_each = local.pipeline_permissions

  project  = var.project_id
  location = var.region
  name     = google_clouddeploy_delivery_pipeline.service.name
  role     = google_project_iam_custom_role.pipeline[each.key].name
  member   = "serviceAccount:${local.principals[each.key]}"
}

resource "google_project_iam_custom_role" "target" {
  project     = var.project_id
  role_id     = "agoraTargetSubmit${local.role_suffix}"
  title       = "Inspect the selected rollout target"
  permissions = ["clouddeploy.targets.get"]
}

resource "google_clouddeploy_target_iam_member" "submit" {
  project  = var.project_id
  location = var.region
  name     = google_clouddeploy_target.service.name
  role     = google_project_iam_custom_role.target.name
  member   = "serviceAccount:${local.submitter}"
}

resource "google_project_iam_custom_role" "service" {
  for_each = local.service_permissions

  project     = var.project_id
  role_id     = "agoraService${title(each.key)}${local.role_suffix}"
  title       = "Agora service ${each.key}"
  permissions = each.value
}

# Bootstrap owns first creation. This module grants access without writing the service specification.
resource "google_cloud_run_v2_service_iam_member" "execution" {
  for_each = local.service_permissions

  project  = var.project_id
  location = var.region
  name     = var.name
  role     = google_project_iam_custom_role.service[each.key].name
  member   = "serviceAccount:${local.principals[each.key]}"
}

resource "google_service_account_iam_member" "submit_execution" {
  for_each = local.workers

  service_account_id = google_service_account.execution[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.submitter}"
}

resource "google_service_account_iam_member" "foundation_execution" {
  for_each = google_service_account.execution

  service_account_id = each.value.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.foundation_service_account}"
}

resource "google_service_account_iam_member" "deploy_runtime" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.runtime_service_account}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.execution["deploy"].email}"
}

resource "google_project_iam_custom_role" "probe_execution" {
  project     = var.project_id
  role_id     = "agoraRolloutProbeExecution${local.role_suffix}"
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
    deploy = local.image_repository
    verify = try(split("/", var.verification_image)[2], "invalid")
  }

  project    = var.project_id
  location   = var.region
  repository = each.value
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${local.workers[each.key]}"
}
