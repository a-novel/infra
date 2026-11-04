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
  # Frontend Observability's API takes a Grafana Cloud access policy token instead, chosen the same way.
  cloud_token = var.writer ? {
    secret  = "production-grafana-cloud-deploy-token"
    version = var.token_versions.cloud_deploy
    } : {
    secret  = "production-grafana-cloud-plan-token"
    version = var.token_versions.cloud_plan
  }

  # The stack's own data sources: Mimir, which holds every metric Alloy sends, Loki, which holds the
  # cluster's events, and Grafana Cloud's usage metrics.
  metrics = "grafanacloud-prom"
  logs    = "grafanacloud-logs"
  usage   = "grafanacloud-usage"
}

# An ephemeral read keeps the token out of the state and the plan.
ephemeral "google_secret_manager_secret_version" "grafana_token" {
  project = var.management_project_id
  secret  = local.token.secret
  version = local.token.version
}

ephemeral "google_secret_manager_secret_version" "grafana_cloud_token" {
  project = var.management_project_id
  secret  = local.cloud_token.secret
  version = local.cloud_token.version
}

provider "grafana" {
  url      = var.url
  stack_id = var.stack_id
  auth     = ephemeral.google_secret_manager_secret_version.grafana_token.secret_data

  # A Frontend Observability app reads its stack's region from the Grafana Cloud API before calling
  # Frontend Observability's, and the one access policy token serves both.
  cloud_access_policy_token      = ephemeral.google_secret_manager_secret_version.grafana_cloud_token.secret_data
  frontend_o11y_api_access_token = ephemeral.google_secret_manager_secret_version.grafana_cloud_token.secret_data

  # Grafana Cloud sometimes answers 503 for longer than the three default retries wait (14 seconds).
  # Six retries wait up to two minutes, the window the plan gives Google's transient errors.
  retries = 6
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

# The contact point's title and message call these templates: each post names the alert, gives one
# line per firing instance and links its dashboard panel, runbook and silence.
resource "grafana_message_template" "discord" {
  name     = "discord"
  template = file("${path.module}/templates/discord.tmpl")
}
