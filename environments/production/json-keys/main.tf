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

  service                  = "json-keys"
  zone                     = "private"
  project_id               = local.project_id
  region                   = local.region
  management_project_id    = local.management_project_id
  secrets                  = toset([for name in keys(var.secret_versions) : "production-json-keys-${name}"])
  database_service_account = local.database.service_account
  # The jobs and the smoke check run apart from the gRPC server, each reading only what it mounts.
  workloads = merge(
    { for job, config in local.jobs : job => { secrets = toset([for name in setunion(values(config.secrets), local.database_passwords) : "production-json-keys-${name}"]) } },
    { smoke = {} },
  )
  deployer    = local.deployer
  alert_email = var.alert_email
}

module "backups" {
  source = "../../../modules/backup-repository"

  service = "json-keys"
  placement = {
    zone       = local.database.zone
    subnetwork = local.foundation.network.subnet_id
    ip         = local.database.repository_ip
    cos_image  = var.backup_repository.cos_image
  }
  runtime                   = merge(var.backup_repository.runtime, { server_image = local.image.database, credentials_image = local.database.credentials_image })
  project_id                = local.project_id
  region                    = local.region
  bucket                    = "a-novel-management-prod-232403541574-pgbr-json-keys"
  management_project_number = "232403541574"
  repository_ids            = module.runtime.repository_ids
  deployer                  = local.deployer
  notification_channel      = module.runtime.notification_channel
}
