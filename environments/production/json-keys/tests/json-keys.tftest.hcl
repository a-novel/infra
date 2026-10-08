mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email  = "agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
      member = "serviceAccount:agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
      name   = "projects/a-novel-production-prod/serviceAccounts/agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
    }
  }
  mock_data "google_compute_instance_group" {
    defaults = { instances = ["projects/a-novel-production-prod/zones/europe-west1-d/instances/agora-database-json-keys-test"] }
  }
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      region              = "europe-west1"
      workload_project_id = "a-novel-production-prod"
      network = {
        network_id   = "projects/a-novel-production-prod/global/networks/agora-production"
        subnet_id    = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-europe-west1"
        network_tags = { json_keys = "agora-json-keys" }
      }
      database_hosts = {
        json_keys = {
          instance_group_manager = "agora-database-json-keys"
          private_ip             = "10.20.0.5"
          port                   = 5432
          service_account        = "agora-json-keys-database@a-novel-production-prod.iam.gserviceaccount.com"
          zone                   = "europe-west1-d"
        }
      }
    }
  }
}

run "serves_privately_from_pinned_images_and_secrets" {
  command = plan

  assert {
    condition = (
      google_cloud_run_v2_service.grpc.ingress == "INGRESS_TRAFFIC_INTERNAL_ONLY" &&
      !google_cloud_run_v2_service.grpc.invoker_iam_disabled &&
      google_cloud_run_v2_service.grpc.template[0].vpc_access[0].egress == "ALL_TRAFFIC"
    )
    error_message = "JSON Keys must stay internal, IAM-authenticated and routed through the VPC."
  }

  assert {
    condition = alltrue([for image in concat(
      [google_cloud_run_v2_service.grpc.template[0].containers[0].image],
      [for job in google_cloud_run_v2_job.application : job.template[0].template[0].containers[0].image],
      ) : can(regex("^europe-west1-docker\\.pkg\\.dev/a-novel-production-prod/agora-json-keys-private-production/service-json-keys/[a-z/]+@sha256:[a-f0-9]{64}$", image))
    ])
    error_message = "Workloads must run the Artifact Registry copy of each image, pinned by digest."
  }

  assert {
    condition = alltrue([for env in google_cloud_run_v2_service.grpc.template[0].containers[0].env :
      length(env.value_source) == 0 || can(regex("^[1-9][0-9]*$", env.value_source[0].secret_key_ref[0].version))
    ])
    error_message = "Secrets must be pinned to numeric versions, never latest."
  }

  assert {
    condition = (
      google_cloud_run_v2_job.application["migrations"].run_execution_token != null &&
      google_cloud_run_v2_job.application["rotatekeys"].run_execution_token == null
    )
    error_message = "Only migrations run during apply."
  }
}

run "rejects_an_unpinned_image" {
  command = plan

  variables {
    images = {
      grpc       = "ghcr.io/a-novel/service-json-keys/grpc:latest"
      migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.8.0@sha256:95dd4bb962d5345f171b718dcd888d6bc11e1856022d442a8a80be4a6bdc86f6"
      rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.8.0@sha256:d7eb0811340b903a7d9a20b75911711f8d35b95687250792c167777be7aeac6c"
    }
  }

  expect_failures = [var.images]
}
