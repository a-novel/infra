provider "google" {
  project = local.private_project_id
  region  = local.region
}

# The foundation root owns the projects, the network and the database host.
data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "foundation"
  }
}

locals {
  foundation            = data.terraform_remote_state.foundation.outputs
  private_project_id    = local.foundation.production_projects["private"].project_id
  api_project_id        = local.foundation.production_projects["public-api"].project_id
  region                = local.foundation.region
  management_project_id = "a-novel-management-prod"
  deployer              = "infra-foundation@${local.management_project_id}.iam.gserviceaccount.com"
  database              = local.foundation.database_hosts["authentication"]
}

# Database migrations run beside the database in the private zone.
module "private_runtime" {
  source = "../../../modules/service-runtime"

  service               = "authentication"
  zone                  = "private"
  project_id            = local.private_project_id
  region                = local.region
  management_project_id = local.management_project_id
  secrets               = toset(["production-authentication-postgres-password"])
  deployer              = local.deployer
  alert_email           = var.alert_email
}

# The public REST API runs in the public-api zone.
module "api_runtime" {
  source = "../../../modules/service-runtime"

  service               = "authentication"
  zone                  = "public-api"
  project_id            = local.api_project_id
  region                = local.region
  management_project_id = local.management_project_id
  secrets               = toset([for name in keys(var.secret_versions) : "production-authentication-${name}"])
  deployer              = local.deployer
  alert_email           = var.alert_email
}

module "backups" {
  source = "../../../modules/backup-repository"

  service = "authentication"
  placement = {
    zone       = local.database.zone
    subnetwork = local.foundation.network.subnet_id
    cos_image  = var.backup_repository.cos_image
  }
  runtime                   = var.backup_repository.runtime
  project_id                = local.private_project_id
  region                    = local.region
  bucket                    = "a-novel-management-prod-232403541574-pgbr-authentication"
  management_project_number = "232403541574"
  database = {
    group           = local.database.instance_group_manager
    zone            = local.database.zone
    service_account = local.database.service_account
  }
  repository_ids       = module.private_runtime.repository_ids
  deployer             = local.deployer
  notification_channel = module.private_runtime.notification_channel
}

resource "google_monitoring_alert_policy" "rest_error_rate" {
  project      = local.api_project_id
  display_name = "Agora authentication REST 5xx error rate"
  combiner     = "OR"
  enabled      = true
  severity     = "ERROR"

  documentation {
    content   = "Owner: production operator. More than 10% of authentication REST requests returned 5xx for five minutes. Inspect the service's revision logs and dependency health before changing traffic."
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "5xx responses exceed 10%"

    condition_threshold {
      filter             = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"agora-authentication-rest\" AND resource.label.location = \"${local.region}\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.response_code_class = \"5xx\""
      denominator_filter = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"agora-authentication-rest\" AND resource.label.location = \"${local.region}\" AND metric.type = \"run.googleapis.com/request_count\""
      comparison         = "COMPARISON_GT"
      threshold_value    = 0.10
      duration           = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.service_name"]
      }

      denominator_aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.service_name"]
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"

      trigger {
        count = 1
      }
    }
  }

  notification_channels = [module.api_runtime.notification_channel]
  deletion_policy       = "DELETE"
}
