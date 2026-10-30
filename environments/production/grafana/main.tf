provider "google" {
  project = var.management_project_id
}

locals {
  # Pull requests and the drift check run as the plan identity, which bootstrap lets read only the
  # read-only token.
  token = var.writer ? {
    secret  = "production-grafana-deploy-token"
    version = var.token_versions.deploy
    } : {
    secret  = "production-grafana-plan-token"
    version = var.token_versions.plan
  }

  # The stack's own data sources: Mimir, which holds every metric Alloy sends, and Grafana Cloud's
  # usage metrics.
  metrics = "grafanacloud-prom"
  usage   = "grafanacloud-usage"
}

# An ephemeral read keeps the token out of the state and the plan.
ephemeral "google_secret_manager_secret_version" "grafana_token" {
  project = var.management_project_id
  secret  = local.token.secret
  version = local.token.version
}

provider "grafana" {
  url  = var.url
  auth = ephemeral.google_secret_manager_secret_version.grafana_token.secret_data
}

# Holds every alert rule group and dashboard this root manages.
resource "grafana_folder" "production" {
  uid   = "production"
  title = "Production"
}

# Every alert posts to the Discord contact point, which core creates by hand so its webhook never
# reaches the state. A firing alert posts again every four hours.
resource "grafana_notification_policy" "discord" {
  contact_point = var.contact_point
  group_by      = ["grafana_folder", "alertname"]
}
