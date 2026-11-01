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
  database   = local.foundation.database_hosts["authentication"]
  # The backup repository VM runs the release's PostgreSQL image from the production repository.
  database_image = regex("^ghcr\\.io/a-novel/(?P<path>[^:@]+):[^@]+@(?P<digest>sha256:[a-f0-9]{64})$", var.images.database)
}

# The cluster runs every release from this service's production repository.
module "private_runtime" {
  source = "../../../modules/service-runtime"

  service                  = "authentication"
  project_id               = local.project_id
  region                   = local.region
  database_service_account = local.database.service_account
  alert_email              = var.alert_email
}

module "backups" {
  source = "../../../modules/backup-repository"

  service = "authentication"
  placement = {
    zone       = local.database.zone
    subnetwork = local.foundation.network.subnet_id
    ip         = local.database.repository_ip
    cos_image  = var.backup_repository.cos_image
  }
  runtime                   = merge(var.backup_repository.runtime, { server_image = "${module.private_runtime.repositories["production"]}/${local.database_image.path}@${local.database_image.digest}", credentials_image = local.database.credentials_image })
  project_id                = local.project_id
  region                    = local.region
  bucket                    = "a-novel-management-prod-232403541574-pgbr-authentication"
  management_project_number = "232403541574"
  repository_ids            = module.private_runtime.repository_ids
  deployer                  = local.deployer
  notification_channel      = module.private_runtime.notification_channel
}

# Authentication's grant on JSON Keys' server goes with that server, which the JSON Keys root
# deletes in the same deploy (a-novel/infra#1208).
removed {
  from = google_cloud_run_v2_service_iam_member.json_keys_invoker

  lifecycle {
    destroy = false
  }
}
