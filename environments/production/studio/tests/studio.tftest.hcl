mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email  = "agora-studio-public@a-novel-public-prod.iam.gserviceaccount.com"
      member = "serviceAccount:agora-studio-public@a-novel-public-prod.iam.gserviceaccount.com"
      name   = "projects/a-novel-public-prod/serviceAccounts/agora-studio-public@a-novel-public-prod.iam.gserviceaccount.com"
    }
  }
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      region = "europe-west1"
      production_projects = {
        private      = { project_id = "a-novel-production-prod" }
        public       = { project_id = "a-novel-public-prod" }
        "public-api" = { project_id = "a-novel-public-api-prod" }
      }
    }
  }
}

run "runs_in_the_public_zone" {
  command = plan

  assert {
    condition     = local.project_id == "a-novel-public-prod"
    error_message = "Studio is a platform: it runs in the public project, outside the VPC and the perimeter."
  }
}
