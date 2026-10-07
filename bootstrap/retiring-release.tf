# Disable before deleting; active automation retains its lifecycle protections.
moved {
  from = google_service_account.automation["release"]
  to   = google_service_account.retiring_release
}

moved {
  from = google_iam_workload_identity_pool_provider.github["release"]
  to   = google_iam_workload_identity_pool_provider.retiring_release
}

resource "google_service_account" "retiring_release" {
  account_id   = local.trust_boundaries.release.service_account_id
  display_name = local.trust_boundaries.release.display_name
  description  = "Keyless GitHub Actions identity for the release trust boundary."
  project      = var.management_project_id
  disabled     = true
}

resource "google_iam_workload_identity_pool_provider" "retiring_release" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = local.trust_boundaries.release.provider_id
  display_name                       = local.trust_boundaries.release.display_name
  description                        = "Trusts only ${local.github.repository} release.yaml on master through production-release."
  disabled                           = true
  deletion_policy                    = "DELETE"

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository"          = "assertion.repository"
    "attribute.repository_id"       = "assertion.repository_id"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.ref"                 = "assertion.ref"
    "attribute.workflow_ref"        = "assertion.workflow_ref"
    "attribute.trust_boundary"      = "'release'"
    "attribute.environment"         = "assertion.environment"
  }

  attribute_condition = join(" && ", [
    "assertion.repository_owner_id == '${local.github.owner_id}'",
    "assertion.repository_id == '${local.github.repository_id}'",
    "assertion.ref == '${local.github.ref}'",
    "assertion.workflow_ref == '${local.github.repository}/.github/workflows/release.yaml@${local.github.ref}'",
    "assertion.environment == 'production-release'",
  ])

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}
