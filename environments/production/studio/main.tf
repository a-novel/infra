# Studio runs on the cluster. This root keeps its release pin, which the cluster root reads from
# terraform.tfvars.
provider "google" {
  project = local.project_id
  region  = local.region
}

# The foundation root owns the workload project.
data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = "a-novel-management-prod-232403541574-tofu-state"
    prefix = "foundation"
  }
}

locals {
  project_id = data.terraform_remote_state.foundation.outputs.workload_project_id
  region     = data.terraform_remote_state.foundation.outputs.region
}
