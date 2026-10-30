# The Grafana root reads its provider tokens from Secret Manager at plan time, as the Sentry root
# does: a stack service account's token for Grafana itself, and a Grafana Cloud access policy's
# token for the Frontend Observability apps. Pull requests and the drift check plan with the plan
# identity, which may hold only the read-only tokens, so a pull request can never write to Grafana.
locals {
  grafana_tokens = {
    plan       = "production-grafana-plan-token"
    foundation = "production-grafana-deploy-token"
    grafana    = "production-grafana-deploy-token"
  }
  grafana_cloud_tokens = {
    plan       = "production-grafana-cloud-plan-token"
    foundation = "production-grafana-cloud-deploy-token"
    grafana    = "production-grafana-cloud-deploy-token"
  }
}

resource "google_secret_manager_secret_iam_member" "grafana_token" {
  for_each = local.grafana_tokens

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.automation[each.key].member
}

resource "google_secret_manager_secret_iam_member" "grafana_cloud_token" {
  for_each = local.grafana_cloud_tokens

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.automation[each.key].member
}

# The provider reads a token's version metadata before its payload. The plan and foundation
# identities read that metadata across the project; the Grafana root's own identity reads it on its
# write tokens alone.
resource "google_secret_manager_secret_iam_member" "grafana_token_metadata" {
  for_each = toset([local.grafana_tokens.grafana, local.grafana_cloud_tokens.grafana])

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value].secret_id
  role      = "roles/secretmanager.viewer"
  member    = google_service_account.automation["grafana"].member
}

# The Grafana root's deploys write its state and lock under grafana/ alone. Listing the bucket shows
# object names, never their content.
resource "google_storage_bucket_iam_member" "grafana_state" {
  bucket = google_storage_bucket.state.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.automation["grafana"].member

  condition {
    title      = "grafana-root-state"
    expression = "resource.type == \"storage.googleapis.com/Bucket\" || resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.state.name}/objects/grafana/\")"
  }
}
