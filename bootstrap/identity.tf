locals {
  plan_project_roles = toset([
    "roles/iam.roleViewer",
    "roles/iam.serviceAccountViewer",
    "roles/iam.workloadIdentityPoolViewer",
    "roles/secretmanager.viewer",
    "roles/serviceusage.serviceUsageViewer",
  ])

  foundation_project_roles = toset([
    "roles/iam.roleAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.workloadIdentityPoolAdmin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.serviceUsageAdmin",
  ])

  release_project_roles = toset([
    # Version metadata is required for preflight, but payload access remains
    # exclusive to runtime identities and named human operators.
    "roles/secretmanager.viewer",
  ])

  recovery_project_roles = toset([
    # Version-state inspection rejects disabled receipt-owned versions. Secret
    # payloads are resolved only by replacement runtime identities.
    "roles/secretmanager.viewer",
  ])

  # Data Access audit entries are private logs. Human operators need the
  # private viewer role to investigate state and secret operations.
  operator_project_roles = setunion(
    local.foundation_project_roles,
    toset(["roles/logging.privateLogViewer"]),
  )

  automation_project_bindings = merge(
    {
      for role in local.plan_project_roles : "plan:${role}" => {
        boundary = "plan"
        role     = role
      }
    },
    {
      for role in local.foundation_project_roles : "foundation:${role}" => {
        boundary = "foundation"
        role     = role
      }
    },
    {
      for role in local.release_project_roles : "release:${role}" => {
        boundary = "release"
        role     = role
      }
    },
    {
      for role in local.recovery_project_roles : "recovery:${role}" => {
        boundary = "recovery"
        role     = role
      }
    },
  )

  operator_project_bindings = {
    for binding in setproduct(var.operator_principals, local.operator_project_roles) :
    "${binding[0]}:${binding[1]}" => {
      principal = binding[0]
      role      = binding[1]
    }
  }

  management_buckets = {
    backups  = google_storage_bucket.backups.name
    receipts = google_storage_bucket.receipts.name
    state    = google_storage_bucket.state.name
  }

  operator_bucket_bindings = {
    for binding in setproduct(var.operator_principals, keys(local.management_buckets)) :
    "${binding[0]}:${binding[1]}" => {
      principal = binding[0]
      bucket    = local.management_buckets[binding[1]]
    }
  }

  plan_state_folders       = local.state_prefixes
  foundation_state_folders = toset(["bootstrap", "foundation"])
  recovery_state_folders   = local.state_prefixes
  state_bucket_viewers     = toset(["release", "recovery"])
}

resource "google_service_account" "automation" {
  for_each = local.trust_boundaries

  account_id   = each.value.service_account_id
  display_name = each.value.display_name
  description  = "Keyless GitHub Actions identity for the ${each.key} trust boundary."
  project      = var.management_project_id

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "Keyless identities for a-novel/infra workflows."
  disabled                  = false
  deletion_policy           = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    google_project_service.management["iam.googleapis.com"],
    google_project_service.management["iamcredentials.googleapis.com"],
    google_project_service.management["sts.googleapis.com"],
  ]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  for_each = local.trust_boundaries

  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = each.value.provider_id
  display_name                       = each.value.display_name
  description                        = "Trusts only ${local.github.repository} ${each.value.workflow_filename} on master${each.value.environment == null ? "" : " through ${each.value.environment}"}."
  disabled                           = false
  deletion_policy                    = "PREVENT"

  attribute_mapping = merge(
    {
      "google.subject"                = "assertion.sub"
      "attribute.repository"          = "assertion.repository"
      "attribute.repository_id"       = "assertion.repository_id"
      "attribute.repository_owner_id" = "assertion.repository_owner_id"
      "attribute.ref"                 = "assertion.ref"
      "attribute.workflow_ref"        = "assertion.workflow_ref"
      # This provider-owned constant prevents GitHub claims from selecting a
      # different CI service account after the provider accepts the token.
      "attribute.trust_boundary" = "'${each.key}'"
    },
    each.value.environment == null ? {} : {
      "attribute.environment" = "assertion.environment"
    },
  )

  attribute_condition = join(" && ", concat(
    [
      "assertion.repository_owner_id == '${local.github.owner_id}'",
      "assertion.repository_id == '${local.github.repository_id}'",
      "assertion.ref == '${local.github.ref}'",
      "assertion.workflow_ref == '${local.github.repository}/.github/workflows/${each.value.workflow_filename}@${local.github.ref}'",
    ],
    each.value.environment == null ? [] : [
      "assertion.environment == '${each.value.environment}'",
    ],
  ))

  oidc {
    # Omitting a custom audience keeps token acceptance pinned to Google's
    # canonical provider-resource audience.
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account_iam_member" "github" {
  for_each = local.trust_boundaries

  service_account_id = google_service_account.automation[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.trust_boundary/${each.key}"
}

# Secret Manager Admin also controls versions and payload access. This custom
# role deliberately owns only the secret-container control plane.
resource "google_project_iam_custom_role" "secret_metadata" {
  role_id     = "infraSecretMetadataAdmin"
  title       = "Infra Secret Metadata Admin"
  description = "Manage Secret Manager containers and their IAM policies without reading, adding, disabling, or destroying secret versions."
  stage       = "GA"

  permissions = [
    "resourcemanager.projects.get",
    "resourcemanager.projects.list",
    "secretmanager.locations.get",
    "secretmanager.locations.list",
    "secretmanager.secrets.create",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.get",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.list",
    "secretmanager.secrets.setIamPolicy",
    "secretmanager.secrets.update",
  ]

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

# A clean-room rebuild temporarily needs to attach replacement runtime
# identities to surviving secret containers and the backup bucket. This role
# changes IAM metadata only: it cannot read/write objects or secret versions.
# It has no standing member; the recovery runbook grants and removes it around
# one replacement-foundation apply.
resource "google_project_iam_custom_role" "recovery_metadata" {
  role_id     = "infraRecoveryMetadataAdmin"
  title       = "Infra Recovery Metadata Admin"
  description = "Manage only backup-bucket and secret-container IAM during an approved clean-room rebuild."
  stage       = "GA"

  permissions = [
    "resourcemanager.projects.get",
    "resourcemanager.projects.list",
    "secretmanager.secrets.get",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.setIamPolicy",
    "storage.buckets.get",
    "storage.buckets.getIamPolicy",
    "storage.buckets.setIamPolicy",
  ]

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [
    google_project_service.management["iam.googleapis.com"],
    google_project_service.management["secretmanager.googleapis.com"],
    google_project_service.management["storage.googleapis.com"],
  ]
}

# Security Reviewer includes private logs and broad inventory access. Planning
# needs only the policy and bucket metadata required to refresh this root.
resource "google_project_iam_custom_role" "plan_metadata" {
  role_id     = "infraPlanMetadataViewer"
  title       = "Infra Plan Metadata Viewer"
  description = "Read project IAM and Cloud Storage control-plane metadata without reading non-state objects or logs."
  stage       = "GA"

  permissions = [
    "resourcemanager.projects.get",
    "resourcemanager.projects.getIamPolicy",
    "resourcemanager.projects.list",
    "storage.buckets.get",
    "storage.buckets.getIamPolicy",
    "storage.buckets.list",
    "storage.managedFolders.get",
    "storage.managedFolders.getIamPolicy",
    "storage.managedFolders.list",
  ]

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_project_iam_member" "automation" {
  for_each = local.automation_project_bindings

  project = var.management_project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.automation[each.value.boundary].email}"
}

resource "google_project_iam_member" "foundation_secret_metadata" {
  project = var.management_project_id
  role    = google_project_iam_custom_role.secret_metadata.name
  member  = "serviceAccount:${google_service_account.automation["foundation"].email}"
}

resource "google_project_iam_member" "plan_metadata" {
  project = var.management_project_id
  role    = google_project_iam_custom_role.plan_metadata.name
  member  = "serviceAccount:${google_service_account.automation["plan"].email}"
}

resource "google_project_iam_member" "operator" {
  for_each = local.operator_project_bindings

  project = var.management_project_id
  role    = each.value.role
  member  = each.value.principal
}

resource "google_project_iam_member" "operator_secret_metadata" {
  for_each = var.operator_principals

  project = var.management_project_id
  role    = google_project_iam_custom_role.secret_metadata.name
  member  = each.value
}

resource "google_storage_bucket_iam_member" "operator_admin" {
  for_each = local.operator_bucket_bindings

  bucket = each.value.bucket
  role   = "roles/storage.admin"
  member = each.value.principal
}

resource "google_storage_bucket_iam_member" "foundation_admin" {
  for_each = local.management_buckets

  bucket = each.value
  role   = "roles/storage.admin"
  member = "serviceAccount:${google_service_account.automation["foundation"].email}"
}

resource "google_storage_bucket_iam_member" "automation_bucket_viewer" {
  for_each = local.state_bucket_viewers

  bucket = google_storage_bucket.state.name
  role   = "roles/storage.bucketViewer"
  member = "serviceAccount:${google_service_account.automation[each.key].email}"
}

# Read-only planning cannot create .tflock objects. The drift workflow must use
# -lock=false and serialize each root with its writer instead of widening access.
resource "google_storage_managed_folder_iam_member" "plan_state" {
  for_each = local.plan_state_folders

  bucket         = google_storage_managed_folder.state[each.value].bucket
  managed_folder = google_storage_managed_folder.state[each.value].name
  role           = "roles/storage.objectViewer"
  member         = "serviceAccount:${google_service_account.automation["plan"].email}"
}

resource "google_storage_managed_folder_iam_member" "foundation_state" {
  for_each = local.foundation_state_folders

  bucket         = google_storage_managed_folder.state[each.value].bucket
  managed_folder = google_storage_managed_folder.state[each.value].name
  role           = "roles/storage.objectAdmin"
  member         = "serviceAccount:${google_service_account.automation["foundation"].email}"
}

resource "google_storage_managed_folder_iam_member" "release_state" {
  bucket         = google_storage_managed_folder.state["release"].bucket
  managed_folder = google_storage_managed_folder.state["release"].name
  role           = "roles/storage.objectAdmin"
  member         = "serviceAccount:${google_service_account.automation["release"].email}"
}

resource "google_storage_managed_folder_iam_member" "recovery_state" {
  for_each = local.recovery_state_folders

  bucket         = google_storage_managed_folder.state[each.value].bucket
  managed_folder = google_storage_managed_folder.state[each.value].name
  role           = "roles/storage.objectAdmin"
  member         = "serviceAccount:${google_service_account.automation["recovery"].email}"
}

resource "google_storage_managed_folder_iam_member" "release_receipt_creator" {
  bucket         = google_storage_managed_folder.receipt["production"].bucket
  managed_folder = google_storage_managed_folder.receipt["production"].name
  role           = "roles/storage.objectCreator"
  member         = "serviceAccount:${google_service_account.automation["release"].email}"
}

resource "google_storage_managed_folder_iam_member" "release_receipt_viewer" {
  bucket         = google_storage_managed_folder.receipt["production"].bucket
  managed_folder = google_storage_managed_folder.receipt["production"].name
  role           = "roles/storage.objectViewer"
  member         = "serviceAccount:${google_service_account.automation["release"].email}"
}

resource "google_storage_bucket_iam_member" "recovery_backup_viewer" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.automation["recovery"].email}"

  # The GitHub runner verifies only exact immutable manifest metadata. Backup
  # dumps are read later by the replacement runtime, never by CI.
  condition {
    title       = "RecoveryManifestsOnly"
    description = "Allow protected recovery to read only committed backup manifests, not database dumps."
    expression  = "resource.type == 'storage.googleapis.com/Object' && resource.name.startsWith('projects/_/buckets/${google_storage_bucket.backups.name}/objects/v1/') && resource.name.endsWith('/completed.manifest')"
  }
}

resource "google_storage_managed_folder_iam_member" "recovery_receipt_viewer" {
  bucket         = google_storage_managed_folder.receipt["production/success"].bucket
  managed_folder = google_storage_managed_folder.receipt["production/success"].name
  role           = "roles/storage.objectViewer"
  member         = "serviceAccount:${google_service_account.automation["recovery"].email}"
}

resource "google_storage_managed_folder_iam_member" "recovery_receipt_creator" {
  bucket         = google_storage_managed_folder.receipt["recovery"].bucket
  managed_folder = google_storage_managed_folder.receipt["recovery"].name
  role           = "roles/storage.objectCreator"
  member         = "serviceAccount:${google_service_account.automation["recovery"].email}"
}

resource "google_project_iam_audit_config" "management" {
  for_each = local.audited_services

  project = var.management_project_id
  service = each.value

  audit_log_config {
    log_type = "ADMIN_READ"
  }

  audit_log_config {
    log_type = "DATA_READ"
  }

  audit_log_config {
    log_type = "DATA_WRITE"
  }
}
