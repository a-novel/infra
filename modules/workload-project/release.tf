locals {
  release_environment = "${var.labels.environment}-${var.labels.service}-release"
  identity_pool       = "projects/${var.management.project_number}/locations/global/workloadIdentityPools/github-actions"
  bucket_prefix       = "${var.management.project_id}-${var.management.project_number}"

  # Sibling namespaces avoid inheriting the legacy release/recovery grants.
  release_storage = {
    state = {
      bucket = "${local.bucket_prefix}-tofu-state"
      prefix = "services/${var.project_id}/release/"
    }
    receipts = {
      bucket = "${local.bucket_prefix}-deployment-receipts"
      prefix = "services/${var.project_id}/production/"
    }
  }
}

resource "google_service_account" "release" {
  project      = google_project.service.project_id
  account_id   = "infra-release"
  display_name = "Service release"
  description  = "Keyless release writer for ${var.project_id}."

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.api["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool_provider" "release" {
  project                            = var.management.project_id
  workload_identity_pool_id          = "github-actions"
  workload_identity_pool_provider_id = "r-${var.project_id}"
  display_name                       = "Service release"
  description                        = "Trusts only the ${local.release_environment} release workflow on master."
  deletion_policy                    = "PREVENT"

  attribute_mapping = {
    # Keep the subject below Google's 127-byte limit for long service names.
    "google.subject" = "assertion.repository_id + ':' + assertion.environment"
    # The provider, not a caller-supplied claim, selects the service account.
    "attribute.service_release" = "'${var.project_id}'"
  }

  attribute_condition = join(" && ", [
    "assertion.repository_owner_id == '131281268'",
    "assertion.repository_id == '1344262359'",
    "assertion.ref == 'refs/heads/master'",
    "assertion.workflow_ref == 'a-novel/infra/.github/workflows/release.yaml@refs/heads/master'",
    "assertion.environment == '${local.release_environment}'",
  ])

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account_iam_member" "release_federation" {
  service_account_id = google_service_account.release.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.identity_pool}/attribute.service_release/${var.project_id}"

  depends_on = [google_iam_workload_identity_pool_provider.release]
}

resource "google_storage_managed_folder" "release" {
  for_each = local.release_storage

  bucket          = each.value.bucket
  name            = each.value.prefix
  force_destroy   = false
  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_managed_folder_iam_member" "release" {
  for_each = {
    state_writer    = { folder = "state", role = "roles/storage.objectAdmin" }
    receipt_creator = { folder = "receipts", role = "roles/storage.objectCreator" }
    receipt_reader  = { folder = "receipts", role = "roles/storage.objectViewer" }
  }

  bucket         = google_storage_managed_folder.release[each.value.folder].bucket
  managed_folder = google_storage_managed_folder.release[each.value.folder].name
  role           = each.value.role
  member         = "serviceAccount:${google_service_account.release.email}"
}

resource "google_storage_bucket_iam_member" "release_metadata" {
  bucket = google_storage_managed_folder.release["state"].bucket
  role   = "roles/storage.bucketViewer"
  member = "serviceAccount:${google_service_account.release.email}"
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
    title       = "ServiceOperationEvidence-${var.project_id}"
    description = "Read only this service's operation and native-completion records."
    expression = "resource.type == 'storage.googleapis.com/Object' && (${join(" || ", [
      for prefix in ["operations", "native-success"] :
      "resource.name.startsWith('projects/_/buckets/${local.release_storage.receipts.bucket}/objects/${local.release_storage.receipts.prefix}${prefix}/')"
    ])})"
  }
}
