provider "google" {
  project = local.project_id
  region  = local.region
}

# The foundation root owns the network and the database host.
data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "foundation"
  }
}

locals {
  foundation            = data.terraform_remote_state.foundation.outputs
  project_id            = local.foundation.workload_project_id
  region                = local.foundation.region
  management_project_id = "a-novel-management-prod"
  deployer              = "infra-foundation@${local.management_project_id}.iam.gserviceaccount.com"
  database              = local.foundation.database_hosts["json_keys"]
}

module "runtime" {
  source = "../../../modules/service-runtime"

  service               = "json-keys"
  zone                  = "private"
  project_id            = local.project_id
  region                = local.region
  management_project_id = local.management_project_id
  secrets               = toset([for name in keys(var.secret_versions) : "production-json-keys-${name}"])
  deployer              = local.deployer
  alert_email           = var.alert_email
}

module "backups" {
  source = "../../../modules/backup-repository"

  service = "json-keys"
  placement = {
    zone       = local.database.zone
    subnetwork = local.foundation.network.subnet_id
    cos_image  = var.backup_repository.cos_image
  }
  runtime                   = var.backup_repository.runtime
  project_id                = local.project_id
  region                    = local.region
  bucket                    = "a-novel-management-prod-232403541574-pgbr-json-keys"
  management_project_number = "232403541574"
  database = {
    group           = local.database.instance_group_manager
    zone            = local.database.zone
    service_account = local.database.service_account
  }
  repository_ids       = module.runtime.repository_ids
  deployer             = local.deployer
  notification_channel = module.runtime.notification_channel
}
