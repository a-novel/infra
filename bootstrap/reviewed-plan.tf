# Pull requests plan the Grafana and GitHub roots as infra-reviewed-plan, the only plan identity that
# reads a third party's credential: the Grafana plan tokens and the GitHub Plan App keys. A pull
# request mints it only once a reviewer of the plan environment admits its run.
locals {
  reviewed_plan_secrets = toset(concat(
    ["production-grafana-plan-token", "production-grafana-cloud-plan-token"],
    [for owner in local.github_root_owners : "production-github-plan-key-${owner}"],
  ))
}

resource "google_secret_manager_secret_iam_member" "reviewed_plan" {
  for_each = local.reviewed_plan_secrets

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.automation["reviewed_plan"].member
}

# The providers read a version's metadata before its payload.
resource "google_secret_manager_secret_iam_member" "reviewed_plan_metadata" {
  for_each = local.reviewed_plan_secrets

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value].secret_id
  role      = "roles/secretmanager.viewer"
  member    = google_service_account.automation["reviewed_plan"].member
}

# It reads the two roots' state, without creating .tflock objects. Listing the bucket shows object
# names, never their content.
resource "google_storage_bucket_iam_member" "reviewed_plan_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.automation["reviewed_plan"].member

  condition {
    title      = "grafana-and-github-root-state"
    expression = "resource.type == \"storage.googleapis.com/Bucket\" || resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.state.name}/objects/grafana/\") || resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.state.name}/objects/github/\")"
  }
}
