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

data "sentry_team" "owner" {
  organization = var.organization
  slug         = var.team
}

resource "sentry_project" "service" {
  for_each = var.projects

  organization = var.organization
  teams        = [data.sentry_team.owner.slug]
  name         = each.key
  slug         = each.key
  platform     = "go"

  # Deleting a project deletes its issues and history and invalidates its DSN.
  lifecycle {
    prevent_destroy = true
  }
}

# Spike protection drops events above the project's usual rate, so one runaway fault cannot spend
# the month's shared error quota.
resource "sentry_project_spike_protection" "service" {
  for_each = sentry_project.service

  organization = var.organization
  project      = each.value.slug
  enabled      = true
}
