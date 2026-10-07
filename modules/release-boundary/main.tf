locals {
  release_environment = var.zone == null ? "${var.labels.environment}-${var.labels.service}-release" : "${var.labels.environment}-${var.labels.service}-${var.zone}-release"
  scope               = var.zone == null ? var.project_id : "${var.labels.environment}:${var.project_id}:${var.labels.service}:${var.zone}"
  provider_id         = var.zone == null ? "r-${var.project_id}" : "r-${substr(sha256(local.scope), 0, 28)}"
  storage_prefix      = var.zone == null ? "services/${var.project_id}" : "workloads/${var.labels.environment}/${var.zone}/${var.project_id}/${var.labels.service}"
  identity_pool       = "projects/${var.management.project_number}/locations/global/workloadIdentityPools/github-actions"
  bucket_prefix       = "${var.management.project_id}-${var.management.project_number}"

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

moved {
  from = google_service_account.release
  to   = google_service_account.retiring_release
}

moved {
  from = google_iam_workload_identity_pool_provider.release
  to   = google_iam_workload_identity_pool_provider.retiring_release
}

resource "google_service_account" "retiring_release" {
  project = var.project_id
  # Authentication's full public-api suffix exceeds the 30-character account limit.
  account_id      = var.zone == null ? "infra-release" : "infra-${var.labels.service}-${var.zone == "public-api" ? "api" : var.zone}"
  display_name    = "Service release"
  description     = "Keyless release writer for ${var.project_id}."
  disabled        = true
  deletion_policy = "DELETE"
}

resource "google_iam_workload_identity_pool_provider" "retiring_release" {
  project                            = var.management.project_id
  workload_identity_pool_id          = "github-actions"
  workload_identity_pool_provider_id = local.provider_id
  display_name                       = "Service release"
  description                        = "Trusts only the ${local.release_environment} release workflow on master."
  deletion_policy                    = "DELETE"
  disabled                           = true

  attribute_mapping = {
    # Keep the subject below Google's 127-byte limit for long service names.
    "google.subject" = "assertion.repository_id + ':' + assertion.environment"
    # The provider, not a caller-supplied claim, selects the service account.
    "attribute.service_release" = "'${local.scope}'"
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

}

resource "google_service_account_iam_member" "release_federation" {
  service_account_id = google_service_account.retiring_release.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${local.identity_pool}/attribute.service_release/${local.scope}"

  depends_on = [google_iam_workload_identity_pool_provider.retiring_release]
}

resource "google_storage_managed_folder" "release" {
  for_each = local.release_storage

  bucket          = each.value.bucket
  name            = each.value.prefix
  force_destroy   = false
  deletion_policy = "PREVENT"
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
  member         = "serviceAccount:${google_service_account.retiring_release.email}"
}

resource "google_storage_bucket_iam_member" "release_metadata" {
  bucket = google_storage_managed_folder.release["state"].bucket
  role   = "roles/storage.bucketViewer"
  member = "serviceAccount:${google_service_account.retiring_release.email}"
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
    title       = "ServiceOperationEvidence-${var.zone == null ? var.project_id : local.provider_id}"
    description = "Read only this service's operation and rotation records."
    expression = "resource.type == 'storage.googleapis.com/Object' && (${join(" || ", [
      for prefix in ["operations", "rotations"] :
      "resource.name.startsWith('projects/_/buckets/${local.release_storage.receipts.bucket}/objects/${local.release_storage.receipts.prefix}${prefix}/')"
    ])})"
  }
}
