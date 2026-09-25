locals {
  rotation_workflow = "projects/${var.runtime.project_id}/locations/${var.runtime.region}/workflows/agora-json-keys-rotation"
  rotation_guard    = "services/${var.runtime.project_id}/release/operation.json"
  rotation_records  = "services/${var.runtime.project_id}/production/rotations/"
  receipt_bucket    = "${trimsuffix(var.state_bucket, "-tofu-state")}-deployment-receipts"
}

resource "google_service_account" "dispatcher" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  project      = var.runtime.project_id
  account_id   = "agora-json-keys-rotation"
  display_name = "Guarded JSON Keys rotation"

  lifecycle { prevent_destroy = true }
}

resource "google_service_account_iam_member" "foundation_dispatcher" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  service_account_id = google_service_account.dispatcher[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.foundation_service_account}"
}

resource "google_project_iam_custom_role" "rotation_read" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  project     = var.runtime.project_id
  role_id     = "agoraRotationRead"
  title       = "Inspect rotation job and executions"
  permissions = ["run.jobs.get", "run.executions.get"]
}

resource "google_cloud_run_v2_job_iam_member" "dispatcher" {
  for_each = var.runtime.service == "json-keys" ? toset(["read", "execute"]) : toset([])

  project  = var.runtime.project_id
  location = var.runtime.region
  name     = "agora-json-keys-rotatekeys"
  role     = each.key == "read" ? google_project_iam_custom_role.rotation_read[0].name : "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.dispatcher[0].email}"
}

resource "google_project_iam_member" "dispatcher_operations" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  project = var.runtime.project_id
  role    = google_project_iam_custom_role.operation_read.name
  member  = "serviceAccount:${google_service_account.dispatcher[0].email}"
}

resource "google_storage_bucket_iam_member" "dispatcher_guard" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  bucket = var.state_bucket
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${google_service_account.dispatcher[0].email}"

  condition {
    title      = "RotationGuard-${var.runtime.project_id}"
    expression = "resource.type == 'storage.googleapis.com/Object' && resource.name == 'projects/_/buckets/${var.state_bucket}/objects/${local.rotation_guard}'"
  }
}

resource "google_storage_bucket_iam_member" "dispatcher_records" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  bucket = local.receipt_bucket
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.dispatcher[0].email}"

  condition {
    title      = "RotationEvidence-${var.runtime.project_id}"
    expression = "resource.type == 'storage.googleapis.com/Object' && resource.name.startsWith('projects/_/buckets/${local.receipt_bucket}/objects/${local.rotation_records}')"
  }
}

resource "google_workflows_workflow" "rotation" {
  count = var.runtime.service == "json-keys" ? 1 : 0

  project                 = var.runtime.project_id
  region                  = var.runtime.region
  name                    = "agora-json-keys-rotation"
  description             = "Serialize scheduled rotation with service operations; retain ambiguous work for inspection."
  service_account         = google_service_account.dispatcher[0].email
  call_log_level          = "LOG_NONE"
  execution_history_level = "EXECUTION_HISTORY_BASIC"
  deletion_protection     = true
  deletion_policy         = "PREVENT"
  labels                  = { environment = "production", service = "json-keys" }
  source_contents = templatefile("${path.module}/rotation.yaml.tftpl", {
    project_id     = var.runtime.project_id
    region         = var.runtime.region
    runtime        = var.runtime.service_account
    workflow       = local.rotation_workflow
    guard          = local.rotation_guard
    state_bucket   = var.state_bucket
    receipt_bucket = local.receipt_bucket
    records        = local.rotation_records
  })

  depends_on = [
    google_service_account_iam_member.foundation_dispatcher,
    google_cloud_run_v2_job_iam_member.dispatcher,
    google_project_iam_member.dispatcher_operations,
    google_storage_bucket_iam_member.dispatcher_guard,
    google_storage_bucket_iam_member.dispatcher_records,
  ]

  lifecycle { prevent_destroy = true }
}
