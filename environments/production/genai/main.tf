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
  database              = local.foundation.database_hosts["genai"]
}

# The runtime identity and the image repositories come first: the deploy copies images into these
# repositories before it applies, so they exist before any workload pins an image.
module "runtime" {
  source = "../../../modules/service-runtime"

  service                  = "genai"
  zone                     = "private"
  project_id               = local.project_id
  region                   = local.region
  management_project_id    = local.management_project_id
  secrets                  = toset([for name in keys(var.secret_versions) : "production-genai-${name}"])
  database_service_account = local.database.service_account
  # The migrations, the sweep and the smoke check run apart from the gRPC server, each reading only
  # what it mounts.
  workloads = {
    migrations = { secrets = toset([for name in values(local.migrations_secret_env) : "production-genai-${name}"]) }
    sweep      = { secrets = toset([for name in values(local.server_secret_env) : "production-genai-${name}"]), telemetry = true }
    smoke      = {}
  }
  deployer    = local.deployer
  alert_email = var.alert_email
}
