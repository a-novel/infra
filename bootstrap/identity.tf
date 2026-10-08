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
  )

  operator_project_bindings = {
    for binding in setproduct(var.operator_principals, local.operator_project_roles) :
    "${binding[0]}:${binding[1]}" => {
      principal = binding[0]
      role      = binding[1]
    }
  }

  management_buckets = merge({
    backups = google_storage_bucket.backups.name
    state   = google_storage_bucket.state.name
  }, { for service, bucket in google_storage_bucket.pgbackrest : "pgbackrest-${service}" => bucket.name })

  operator_bucket_bindings = {
    for binding in setproduct(var.operator_principals, keys(local.management_buckets)) :
    "${binding[0]}:${binding[1]}" => {
      principal = binding[0]
      bucket    = local.management_buckets[binding[1]]
    }
  }
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
  description               = "Keyless identities for registered a-novel workflows."
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
  description                        = "Trusts only ${local.github.repository} ${join(", ", keys(each.value.workflows))} on master${each.value.pull_requests == null ? "" : " and its own pull requests"}."
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
    alltrue([for environment in values(each.value.workflows) : environment == null]) ? {} : {
      "attribute.environment" = "assertion.environment"
    },
  )

  attribute_condition = join(" && ", [
    "assertion.repository_owner_id == '${local.github.owner_id}'",
    "assertion.repository_id == '${local.github.repository_id}'",
    "(${join(" || ", concat(
      [for workflow, environment in each.value.workflows : "(${join(" && ", concat(
        [
          "assertion.ref == '${local.github.ref}'",
          "assertion.workflow_ref == '${local.github.repository}/.github/workflows/${workflow}@${local.github.ref}'",
        ],
        environment == null ? [] : ["assertion.environment == '${environment}'"],
      ))})"],
      each.value.pull_requests == null ? [] : ["(${join(" && ", [
        "assertion.event_name == 'pull_request'",
        "assertion.base_ref == 'master'",
        "assertion.workflow_ref.startsWith('${local.github.repository}/.github/workflows/${each.value.pull_requests}@refs/pull/')",
      ])})"],
    ))})",
  ])

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
# role owns secret containers and version metadata.
resource "google_project_iam_custom_role" "secret_metadata" {
  role_id     = "infraSecretMetadataAdmin"
  title       = "Infra Secret Metadata Admin"
  description = "Manage Secret Manager containers and their IAM policies, and inspect version metadata without accessing payloads or modifying versions."
  stage       = "GA"

  permissions = [
    "resourcemanager.projects.get",
    "secretmanager.locations.get",
    "secretmanager.locations.list",
    "secretmanager.secrets.create",
    "secretmanager.secrets.delete",
    "secretmanager.secrets.get",
    "secretmanager.secrets.getIamPolicy",
    "secretmanager.secrets.list",
    "secretmanager.secrets.setIamPolicy",
    "secretmanager.secrets.update",
    "secretmanager.versions.get",
  ]

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
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

# Read-only planning reads every root's state but cannot create .tflock
# objects, so pull-request and drift plans run with -lock=false.
resource "google_storage_bucket_iam_member" "plan_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.automation["plan"].email}"
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
