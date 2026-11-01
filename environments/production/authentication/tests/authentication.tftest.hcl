# The backup repository VM's identity.
mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email  = "agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
      member = "serviceAccount:agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
      name   = "projects/a-novel-production-prod/serviceAccounts/agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
    }
  }
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      region              = "europe-west1"
      workload_project_id = "a-novel-production-prod"
      network = {
        subnet_id = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-europe-west1"
      }
      database_hosts = {
        authentication = {
          repository_ip     = "10.20.0.7"
          credentials_image = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-authentication-private-tooling/host-credentials@sha256:a5e264fc51c824c52fb6fd59b035e14e52fdc9f77e47b0375b352d8ad9bfd00d"
          service_account   = "agora-auth-database@a-novel-production-prod.iam.gserviceaccount.com"
          zone              = "europe-west1-d"
        }
      }
    }
  }
}

# The cluster root pulls every Authentication release from this repository.
run "keeps_the_repository_the_cluster_pulls_from" {
  command = plan

  assert {
    condition     = module.private_runtime.repositories["production"] == "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-authentication-private-production"
    error_message = "Authentication's private production repository must keep its name: the cluster runs every release from it."
  }
}

# The cluster root deploys the pins this root validates.
run "rejects_an_unpinned_image" {
  command = plan

  variables {
    images = {
      database    = "ghcr.io/a-novel/service-authentication/database:v2.8.0@sha256:95dd4bb962d5345f171b718dcd888d6bc11e1856022d442a8a80be4a6bdc86f6"
      maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.8.0@sha256:95dd4bb962d5345f171b718dcd888d6bc11e1856022d442a8a80be4a6bdc86f6"
      migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.8.0@sha256:95dd4bb962d5345f171b718dcd888d6bc11e1856022d442a8a80be4a6bdc86f6"
      rest        = "ghcr.io/a-novel/service-authentication/rest:latest"
    }
  }

  expect_failures = [var.images]
}
