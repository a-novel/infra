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
  foundation = data.terraform_remote_state.foundation.outputs
  project_id = local.foundation.workload_project_id
  region     = local.foundation.region
  deployer   = "infra-foundation@a-novel-management-prod.iam.gserviceaccount.com"
  database   = local.foundation.database_hosts["genai"]
  # The backup repository VM runs the release's PostgreSQL image from the production repository.
  database_image = regex("^ghcr\\.io/a-novel/(?P<path>[^:@]+):[^@]+@(?P<digest>sha256:[a-f0-9]{64})$", var.images.database)
}

# The cluster runs every release from this service's production repository.
module "runtime" {
  source = "../../../modules/service-runtime"

  service                  = "genai"
  project_id               = local.project_id
  region                   = local.region
  database_service_account = local.database.service_account
  alert_email              = var.alert_email
}

module "backups" {
  source = "../../../modules/backup-repository"

  service = "genai"
  placement = {
    zone       = local.database.zone
    subnetwork = local.foundation.network.subnet_id
    ip         = local.database.repository_ip
    cos_image  = var.backup_repository.cos_image
  }
  runtime                   = merge(var.backup_repository.runtime, { server_image = "${module.runtime.repositories["production"]}/${local.database_image.path}@${local.database_image.digest}", credentials_image = local.database.credentials_image })
  project_id                = local.project_id
  region                    = local.region
  bucket                    = "a-novel-management-prod-232403541574-pgbr-genai"
  management_project_number = "232403541574"
  repository_ids            = module.runtime.repository_ids
  deployer                  = local.deployer
  notification_channel      = module.runtime.notification_channel
}
