resource "google_storage_bucket" "artifacts" {
  project                     = var.project_id
  name                        = var.artifact_bucket
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket_iam_member" "artifacts" {
  for_each = {
    deploy_creator = { account = "deploy", role = "roles/storage.objectCreator" }
    deploy_reader  = { account = "deploy", role = "roles/storage.objectViewer" }
    verify_creator = { account = "verify", role = "roles/storage.objectCreator" }
    verify_reader  = { account = "verify", role = "roles/storage.objectViewer" }
  }

  bucket = google_storage_bucket.artifacts.name
  role   = each.value.role
  member = "serviceAccount:${local.workers[each.value.account]}"
}

# The parent receipt folder remains owned by workload-project. Readers here cannot
# read its sibling intents/receipts or write source, even in the management project.
resource "google_storage_managed_folder" "source" {
  bucket          = var.receipt_bucket
  name            = "services/${var.project_id}/production/sources/"
  force_destroy   = false
  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_managed_folder_iam_member" "source" {
  for_each = {
    deploy        = google_service_account.execution["deploy"].email
    service_agent = "service-${data.google_project.service.number}@gcp-sa-clouddeploy.iam.gserviceaccount.com"
  }

  bucket         = google_storage_managed_folder.source.bucket
  managed_folder = google_storage_managed_folder.source.name
  role           = "roles/storage.objectViewer"
  member         = "serviceAccount:${each.value}"
}
