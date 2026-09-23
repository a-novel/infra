locals {
  release_member = "serviceAccount:infra-release@${var.runtime.project_id}.iam.gserviceaccount.com"
  job_names = toset([for role in(var.runtime.service == "json-keys" ? ["migrations", "rotatekeys"] : ["migrations"]) :
    "agora-${var.runtime.service}-${role}"
  ])
}

resource "google_project_iam_custom_role" "job_update" {
  project = var.runtime.project_id
  role_id = "agoraApplicationJobUpdate"
  title   = "Update and inspect application jobs"
  permissions = [
    "run.jobs.get",
    "run.jobs.update",
    "run.executions.get",
    "run.executions.list",
  ]
}

resource "google_cloud_run_v2_job_iam_member" "update" {
  for_each = local.job_names

  project  = var.runtime.project_id
  location = var.runtime.region
  name     = each.value
  role     = google_project_iam_custom_role.job_update.name
  member   = local.release_member
}

resource "google_cloud_run_v2_job_iam_member" "execute" {
  for_each = local.job_names

  project  = var.runtime.project_id
  location = var.runtime.region
  name     = each.value
  role     = "roles/run.invoker"
  member   = local.release_member
}

# Cloud Run operation resources belong to the project/location, outside the job hierarchy.
resource "google_project_iam_custom_role" "operation_read" {
  project     = var.runtime.project_id
  role_id     = "agoraApplicationJobOperationRead"
  title       = "Observe application job operations"
  permissions = ["run.operations.get"]
}

resource "google_project_iam_member" "operation_read" {
  project = var.runtime.project_id
  role    = google_project_iam_custom_role.operation_read.name
  member  = local.release_member
}

resource "google_service_account_iam_member" "attach_runtime" {
  service_account_id = "projects/${var.runtime.project_id}/serviceAccounts/${var.runtime.service_account}"
  role               = "roles/iam.serviceAccountUser"
  member             = local.release_member
}
