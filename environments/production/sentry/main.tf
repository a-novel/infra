# Sentry retires (a-novel/infra#1215). This root keeps only its provider, so the deploy deletes what
# it configured; the root itself goes next.
provider "google" {
  project = var.management_project_id
}

locals {
  # Pull requests and the drift check run as the plan identity, which bootstrap lets read only the
  # read-only token.
  token = var.writer ? {
    secret  = "production-sentry-deploy-token"
    version = var.token_versions.deploy
    } : {
    secret  = "production-sentry-plan-token"
    version = var.token_versions.plan
  }
}

# An ephemeral read keeps the token out of the state and the plan.
ephemeral "google_secret_manager_secret_version" "sentry_token" {
  project = var.management_project_id
  secret  = local.token.secret
  version = local.token.version
}

provider "sentry" {
  base_url = var.base_url
  token    = ephemeral.google_secret_manager_secret_version.sentry_token.secret_data
}
