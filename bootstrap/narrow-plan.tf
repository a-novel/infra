# Temporary. infra-plan reads the workload project through Viewer, which also reads the pods' logs,
# and no deny policy can refuse a GKE permission. infra-narrow-plan holds the roles meant to replace
# Viewer, foundation's plan_project_roles, and what infra-plan holds here, so a pull request that
# plans as it proves those roles before infra-plan drops Viewer. Delete this file then.
resource "google_service_account" "narrow_plan" {
  account_id   = "infra-narrow-plan"
  display_name = "Infra narrow plan"
  description  = "Temporary keyless GitHub Actions identity that proves infra-plan's narrow roles."
  project      = var.management_project_id
}

# It trusts the workflows infra-plan trusts, under its own constant.
resource "google_iam_workload_identity_pool_provider" "narrow_plan" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-narrow-plan"
  display_name                       = "Infra narrow plan"
  description                        = google_iam_workload_identity_pool_provider.github["plan"].description
  disabled                           = false
  attribute_mapping                  = merge(google_iam_workload_identity_pool_provider.github["plan"].attribute_mapping, { "attribute.trust_boundary" = "'narrow_plan'" })
  attribute_condition                = google_iam_workload_identity_pool_provider.github["plan"].attribute_condition

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "narrow_plan" {
  service_account_id = google_service_account.narrow_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.trust_boundary/narrow_plan"
}

resource "google_project_iam_member" "narrow_plan" {
  for_each = local.plan_project_roles

  project = var.management_project_id
  role    = each.value
  member  = google_service_account.narrow_plan.member
}

resource "google_project_iam_member" "narrow_plan_metadata" {
  project = var.management_project_id
  role    = google_project_iam_custom_role.plan_metadata.name
  member  = google_service_account.narrow_plan.member
}

resource "google_storage_bucket_iam_member" "narrow_plan_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.narrow_plan.member
}
