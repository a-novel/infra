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

# The cluster runs every release from this service's production repository.
module "private_runtime" {
  source = "../../../modules/service-runtime"

  service    = "authentication"
  project_id = local.project_id
  region     = local.region
}

# Authentication's grant on JSON Keys' server goes with that server, which the JSON Keys root
# deletes in the same deploy (a-novel/infra#1208).
removed {
  from = google_cloud_run_v2_service_iam_member.json_keys_invoker

  lifecycle {
    destroy = false
  }
}
