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
module "runtime" {
  source = "../../../modules/service-runtime"

  service    = "json-keys"
  project_id = local.project_id
  region     = local.region
}


# The backup VM's grant on the tooling repository went with that repository (a-novel/infra#1391's
# deploy), so its state goes without a call. The VM's identity, which waited on it, goes next.
removed {
  from = module.backups.google_artifact_registry_repository_iam_member.readers

  lifecycle {
    destroy = false
  }
}
