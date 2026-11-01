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
  foundation = data.terraform_remote_state.foundation.outputs
  project_id = local.foundation.workload_project_id
  region     = local.foundation.region
}

# The cluster pulled every release from this service's repository in the old region until its
# releases moved beside it (a-novel/infra#1208). This root now keeps only the service's pins, which
# the cluster root reads from terraform.tfvars.
removed {
  from = module.runtime

  lifecycle {
    destroy = true
  }
}
