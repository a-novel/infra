# The Grafana root reads its provider token from Secret Manager at plan time, as the Sentry root
# does. Pull requests and the drift check plan with the plan identity, which may hold only the
# read-only token, so a pull request can never write to Grafana.
locals {
  grafana_tokens = {
    plan       = "production-grafana-plan-token"
    foundation = "production-grafana-deploy-token"
  }
}

resource "google_secret_manager_secret_iam_member" "grafana_token" {
  for_each = local.grafana_tokens

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.automation[each.key].member
}
