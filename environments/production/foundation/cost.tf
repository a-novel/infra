locals {
  # Each shell project runs its own Cloud Run services, so each gets its own ceiling.
  shell_projects = {
    public     = module.public_project.project_id
    public-api = module.public_api_project["public-api"].project_id
  }

  # Regional quota IDs are service-defined and known before project creation.
  # Planning must not query APIs that the same plan still needs to enable.
  quota_preferences = merge(
    {
      cloud_run_cpu = {
        project_id = google_project.workload.project_id
        service    = "run.googleapis.com"
        quota_id   = "CpuAllocPerProjectRegion"
        value      = var.cloud_run_cpu_quota_millicpu
      }
      cloud_run_memory = {
        project_id = google_project.workload.project_id
        service    = "run.googleapis.com"
        quota_id   = "MemAllocPerProjectRegion"
        value      = var.cloud_run_memory_quota_bytes
      }
      compute_cpu = {
        project_id = google_project.workload.project_id
        service    = "compute.googleapis.com"
        quota_id   = "CPUS-per-project-region"
        value      = var.compute_cpu_quota
      }
      cluster_compute_cpu = {
        project_id = google_project.workload.project_id
        service    = "compute.googleapis.com"
        quota_id   = "CPUS-per-project-region"
        value      = var.cluster_compute_cpu_quota
        region     = var.cluster_region
      }
    },
    merge([for zone, project_id in local.shell_projects : {
      "${zone}/cloud_run_cpu" = {
        project_id = project_id
        service    = "run.googleapis.com"
        quota_id   = "CpuAllocPerProjectRegion"
        value      = var.shell_cloud_run_quota.cpu_millicpu
      }
      "${zone}/cloud_run_memory" = {
        project_id = project_id
        service    = "run.googleapis.com"
        quota_id   = "MemAllocPerProjectRegion"
        value      = var.shell_cloud_run_quota.memory_bytes
      }
    }]...),
  )
}

data "google_billing_account" "workload" {
  billing_account = var.billing_account_id
  lookup_projects = false
  open            = true
}

resource "google_cloud_quotas_quota_preference" "cost_cap" {
  for_each = local.quota_preferences

  parent     = "projects/${each.value.project_id}"
  service    = each.value.service
  quota_id   = each.value.quota_id
  dimensions = { region = try(each.value.region, var.region) }
  # IAM grants on the foundation identity authorize the request. Google sends
  # quota-review follow-up to the monitored operator address.
  contact_email = var.cost_alert_email
  justification = "A-Novel production cost ceiling; changes require reviewed infrastructure code."

  # Permit deliberate decreases larger than Google's percentage threshold
  # while retaining its block against setting a limit below current usage.
  ignore_safety_checks = "QUOTA_DECREASE_PERCENTAGE_TOO_HIGH"

  quota_config {
    preferred_value = tostring(each.value.value)
  }

  depends_on = [google_project_service.workload]
}

resource "google_monitoring_notification_channel" "cost_email" {
  project = google_project.workload.project_id

  display_name = "A-Novel production cost alerts"
  description  = "Human-reviewed email destination for production infrastructure budget alerts."
  type         = "email"
  enabled      = true
  force_delete = false
  labels       = { email_address = var.cost_alert_email }

  deletion_policy = "PREVENT"

  depends_on = [google_project_service.workload["monitoring.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_monitoring_notification_channel" "operations_email" {
  project = google_project.workload.project_id

  display_name = "A-Novel production operations alerts"
  description  = "Primary human destination for production service, job, backup, and database alerts."
  type         = "email"
  enabled      = true
  force_delete = false
  labels       = { email_address = var.operations_alert_email }

  deletion_policy = "PREVENT"

  depends_on = [google_project_service.workload["monitoring.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_billing_budget" "workload" {
  billing_account = var.billing_account_id
  display_name    = "A-Novel production infrastructure"
  ownership_scope = "BILLING_ACCOUNT"

  budget_filter {
    projects = sort([for number in [
      data.google_project.management.number, google_project.workload.number,
      module.public_project.project_number, module.public_api_project["public-api"].project_number,
    ] : "projects/${number}"])
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = data.google_billing_account.workload.currency_code
      units         = tostring(var.monthly_budget_units)
    }
  }

  # Notify at each share of the budget, for the spend so far and for the month's forecast.
  dynamic "threshold_rules" {
    for_each = setproduct(["CURRENT_SPEND", "FORECASTED_SPEND"], [0.5, 0.75, 0.8, 0.9, 1.0])
    content {
      spend_basis       = threshold_rules.value[0]
      threshold_percent = threshold_rules.value[1]
    }
  }

  all_updates_rule {
    disable_default_iam_recipients  = true
    enable_project_level_recipients = false
    monitoring_notification_channels = sort([
      google_monitoring_notification_channel.cost_email.name,
      google_monitoring_notification_channel.operations_email.name,
    ])
  }

  deletion_policy = "PREVENT"
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_logging_project_bucket_config" "default" {
  project = google_project.workload.project_id

  location         = "global"
  bucket_id        = "_Default"
  retention_days   = 30
  enable_analytics = false
  locked           = false
  deletion_policy  = "PREVENT"

  depends_on = [google_project_service.workload["logging.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
}
