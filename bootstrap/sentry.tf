# The Sentry root reads its provider token from Secret Manager at plan time. Pull requests and the
# drift check plan with the plan identity, which may hold only the read-only token, so a pull request
# can never write to Sentry.
locals {
  sentry_tokens = {
    plan       = "production-sentry-plan-token"
    foundation = "production-sentry-deploy-token"
  }
}

resource "google_secret_manager_secret_iam_member" "sentry_token" {
  for_each = local.sentry_tokens

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.automation[each.key].member
}
