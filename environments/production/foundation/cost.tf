locals {
  quota_preferences = {
    cloud_run_cpu = {
      service = "run.googleapis.com"
      metric  = "run.googleapis.com/cpu_allocation"
      value   = var.cloud_run_cpu_quota_millicpu
    }
    cloud_run_memory = {
      service = "run.googleapis.com"
      metric  = "run.googleapis.com/mem_allocation"
      value   = var.cloud_run_memory_quota_bytes
    }
    compute_cpu = {
      service = "compute.googleapis.com"
      metric  = "compute.googleapis.com/cpus"
      value   = var.compute_cpu_quota
    }
  }

  # A metric can identify several quota IDs. Each cost cap requires one
  # regional match in its declared service.
  quota_id_candidates = {
    for name, preference in local.quota_preferences : name => [
      for quota in data.google_cloud_quotas_quota_infos.service[preference.service].quota_infos :
      quota.quota_id
      if quota.service == preference.service &&
      quota.metric == preference.metric &&
      toset(quota.dimensions) == toset(["region"])
    ]
  }
}

data "google_billing_account" "workload" {
  count = var.recovery_mode ? 0 : 1

  billing_account = var.billing_account_id
  lookup_projects = false
  open            = true
}

data "google_project" "management" {
  count = var.recovery_mode ? 0 : 1

  project_id = var.management_project_id
}

data "google_cloud_quotas_quota_infos" "service" {
  for_each = toset(["compute.googleapis.com", "run.googleapis.com"])

  parent  = "projects/${google_project.workload.project_id}"
  service = each.value

  depends_on = [google_project_service.workload]
}

resource "google_cloud_quotas_quota_preference" "cost_cap" {
  for_each = local.quota_preferences

  parent  = "projects/${google_project.workload.project_id}"
  service = each.value.service
  quota_id = (
    length(local.quota_id_candidates[each.key]) == 1
    ? one(local.quota_id_candidates[each.key])
    : "unavailable"
  )
  dimensions = { region = var.region }
  # IAM grants on the foundation identity authorize the request. Google sends
  # quota-review follow-up to the monitored operator address.
  contact_email = var.cost_alert_email
  justification = "Agora production cost ceiling; changes require reviewed infrastructure code."

  # Permit deliberate decreases larger than Google's percentage threshold
  # while retaining its block against setting a limit below current usage.
  ignore_safety_checks = "QUOTA_DECREASE_PERCENTAGE_TOO_HIGH"

  quota_config {
    preferred_value = tostring(each.value.value)
  }

  lifecycle {
    precondition {
      condition     = length(local.quota_id_candidates[each.key]) == 1
      error_message = "Google Cloud must expose exactly one regional quota for metric ${each.value.metric} in service ${each.value.service}."
    }
  }

  depends_on = [data.google_cloud_quotas_quota_infos.service]
}

resource "google_monitoring_notification_channel" "cost_email" {
  count = var.recovery_mode ? 0 : 1

  project = google_project.workload.project_id

  display_name = "Agora production cost alerts"
  description  = "Human-reviewed email destination for production infrastructure budget alerts."
  type         = "email"
  enabled      = true
  force_delete = false
  labels       = { email_address = var.cost_alert_email }

  deletion_policy = "DELETE"

  depends_on = [google_project_service.workload["monitoring.googleapis.com"]]
}

resource "google_monitoring_notification_channel" "operations_email" {
  count = var.recovery_mode ? 0 : 1

  project = google_project.workload.project_id

  display_name = "Agora production operations alerts"
  description  = "Primary human destination for production service, job, backup, and database alerts."
  type         = "email"
  enabled      = true
  force_delete = false
  labels       = { email_address = var.operations_alert_email }

  deletion_policy = "DELETE"

  depends_on = [google_project_service.workload["monitoring.googleapis.com"]]
}

resource "google_billing_budget" "workload" {
  count = var.recovery_mode ? 0 : 1

  billing_account = var.billing_account_id
  display_name    = "Agora production infrastructure"
  ownership_scope = "BILLING_ACCOUNT"

  budget_filter {
    projects = sort([
      "projects/${data.google_project.management[0].number}",
      "projects/${google_project.workload.number}",
    ])
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = data.google_billing_account.workload[0].currency_code
      units         = tostring(var.monthly_budget_units)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.75
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "FORECASTED_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.75
    spend_basis       = "FORECASTED_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "FORECASTED_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    disable_default_iam_recipients  = true
    enable_project_level_recipients = false
    monitoring_notification_channels = sort([
      google_monitoring_notification_channel.cost_email[0].name,
      google_monitoring_notification_channel.operations_email[0].name,
    ])
  }

  deletion_policy = "DELETE"
}

resource "google_logging_project_bucket_config" "default" {
  project = google_project.workload.project_id

  location         = "global"
  bucket_id        = "_Default"
  retention_days   = 30
  enable_analytics = false
  locked           = false
  deletion_policy  = "DELETE"

  depends_on = [google_project_service.workload["logging.googleapis.com"]]
}

# Keep failed health requests and every application/audit log. Only successful
# probes to Authentication's two exact public health paths are dropped.
resource "google_logging_project_exclusion" "successful_healthchecks" {
  project = google_project.workload.project_id

  name        = "successful-cloud-run-healthchecks"
  description = "Exclude successful Cloud Run request logs for /v2/ping and /v2/healthcheck only."
  disabled    = false
  filter      = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="agora-authentication-rest"
    log_id("run.googleapis.com/requests")
    httpRequest.requestUrl=~"/v2/(ping|healthcheck)(\\?.*)?$"
    httpRequest.status>=200
    httpRequest.status<400
  EOT

  depends_on = [google_project_service.workload["logging.googleapis.com"]]
}
