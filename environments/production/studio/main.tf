provider "google" {
  project = local.project_id
  region  = local.region
}

# The foundation root owns the projects.
data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "foundation"
  }
}

locals {
  foundation            = data.terraform_remote_state.foundation.outputs
  project_id            = local.foundation.production_projects["public"].project_id
  region                = local.foundation.region
  management_project_id = "a-novel-management-prod"
  deployer              = "infra-foundation@${local.management_project_id}.iam.gserviceaccount.com"
}

# Studio serves from the public zone, outside the VPC, and reads no secret: it calls the platform
# services over their public ingress with its own Google ID token.
module "runtime" {
  source = "../../../modules/service-runtime"

  service               = "studio"
  zone                  = "public"
  project_id            = local.project_id
  region                = local.region
  management_project_id = local.management_project_id
  secrets               = toset([])
  deployer              = local.deployer
  alert_email           = var.alert_email
}
