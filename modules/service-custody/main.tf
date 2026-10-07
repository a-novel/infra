locals {
  scope          = var.zone == null ? var.project_id : "${var.labels.environment}:${var.project_id}:${var.labels.service}:${var.zone}"
  scope_id       = var.zone == null ? "r-${var.project_id}" : "r-${substr(sha256(local.scope), 0, 28)}"
  storage_prefix = var.zone == null ? "services/${var.project_id}" : "workloads/${var.labels.environment}/${var.zone}/${var.project_id}/${var.labels.service}"
  bucket_prefix  = "${var.management.project_id}-${var.management.project_number}"

  # Sibling namespaces avoid inheriting the legacy release/recovery grants.
  release_storage = {
    state = {
      bucket = "${local.bucket_prefix}-tofu-state"
      prefix = "${local.storage_prefix}/release/"
    }
    receipts = {
      bucket = "${local.bucket_prefix}-deployment-receipts"
      prefix = "${local.storage_prefix}/production/"
    }
  }
}

resource "google_storage_managed_folder" "release" {
  for_each = local.release_storage

  bucket          = each.value.bucket
  name            = each.value.prefix
  force_destroy   = false
  deletion_policy = "PREVENT"
}

resource "google_storage_managed_folder_iam_member" "plan" {
  bucket         = google_storage_managed_folder.release["state"].bucket
  managed_folder = google_storage_managed_folder.release["state"].name
  role           = "roles/storage.objectViewer"
  member         = "serviceAccount:${var.plan_service_account}"
}

resource "google_storage_bucket_iam_member" "plan_operation_reader" {
  bucket = google_storage_managed_folder.release["receipts"].bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${var.plan_service_account}"

  # Inspection selects exact objects; this condition does not grant bucket listing.
  condition {
    title       = "ServiceOperationEvidence-${var.zone == null ? var.project_id : local.scope_id}"
    description = "Read only this service's operation and rotation records."
    expression = "resource.type == 'storage.googleapis.com/Object' && (${join(" || ", [
      for prefix in ["operations", "rotations"] :
      "resource.name.startsWith('projects/_/buckets/${local.release_storage.receipts.bucket}/objects/${local.release_storage.receipts.prefix}${prefix}/')"
    ])})"
  }
}
