# Studio runs on the cluster. This root keeps its release pin, which the cluster root reads from
# terraform.tfvars, and deletes what the platform ran on Cloud Run (a-novel/infra#1208).
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
  project_id = data.terraform_remote_state.foundation.outputs.production_projects["public"].project_id
  region     = data.terraform_remote_state.foundation.outputs.region
}
