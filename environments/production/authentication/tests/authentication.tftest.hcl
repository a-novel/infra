mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email  = "agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
      member = "serviceAccount:agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
      name   = "projects/a-novel-production-prod/serviceAccounts/agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
    }
  }
  mock_data "google_compute_instance_group" {
    defaults = { instances = ["projects/a-novel-production-prod/zones/europe-west1-d/instances/agora-database-authentication-test"] }
  }
  mock_data "google_cloud_run_v2_service" {
    defaults = { uri = "https://agora-json-keys-grpc-test-ew.a.run.app" }
  }
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      region = "europe-west1"
      production_projects = {
        private      = { project_id = "a-novel-production-prod" }
        "public-api" = { project_id = "a-novel-public-api-prod" }
      }
      network = {
        network_id   = "projects/a-novel-production-prod/global/networks/agora-production"
        subnet_id    = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-europe-west1"
        network_tags = { authentication = "agora-authentication" }
      }
      database_hosts = {
        authentication = {
          instance_group_manager = "agora-database-authentication"
          private_ip             = "10.20.0.4"
          port                   = 5433
          service_account        = "agora-auth-database@a-novel-production-prod.iam.gserviceaccount.com"
          zone                   = "europe-west1-d"
        }
      }
    }
  }
}

run "splits_private_migrations_from_the_public_api" {
  command = plan

  assert {
    condition = (
      google_cloud_run_v2_job.migrations.project == "a-novel-production-prod" &&
      google_cloud_run_v2_service.rest.project == "a-novel-public-api-prod" &&
      google_cloud_run_v2_service.rest.ingress == "INGRESS_TRAFFIC_ALL" &&
      google_cloud_run_v2_service.rest.template[0].vpc_access[0].egress == "PRIVATE_RANGES_ONLY"
    )
    error_message = "Migrations stay private; only the REST API is public, and it reaches private ranges through the VPC only."
  }

  assert {
    condition = alltrue([for env in google_cloud_run_v2_service.rest.template[0].containers[0].env :
      length(env.value_source) == 0 || can(regex("^[1-9][0-9]*$", env.value_source[0].secret_key_ref[0].version))
    ])
    error_message = "Secrets must be pinned to numeric versions, never latest."
  }

  assert {
    condition = (
      google_cloud_run_v2_service.rest.template[0].containers[0].resources[0].cpu_idle == false &&
      !contains([for env in google_cloud_run_v2_service.rest.template[0].containers[0].env : env.name], "WAITLIST_URL")
    )
    error_message = "Authentication keeps CPU for detached mail, and the waitlist stays off unless configured."
  }
}

run "requires_the_waitlist_secret_with_its_url" {
  command = plan

  variables {
    waitlist_url = "https://example.com/waitlist"
  }

  expect_failures = [var.secret_versions]
}
