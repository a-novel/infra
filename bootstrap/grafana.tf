# The Grafana root reads its provider tokens from Secret Manager at plan time, as the Sentry root
# does: a stack service account's token for Grafana itself, and a Grafana Cloud access policy's
# token for the Frontend Observability apps. Pull requests and the drift check plan with the plan
# identity, which may hold only the read-only tokens, so a pull request can never write to Grafana.
locals {
  grafana_tokens = {
    plan       = "production-grafana-plan-token"
    foundation = "production-grafana-deploy-token"
  }
  grafana_cloud_tokens = {
    plan       = "production-grafana-cloud-plan-token"
    foundation = "production-grafana-cloud-deploy-token"
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
