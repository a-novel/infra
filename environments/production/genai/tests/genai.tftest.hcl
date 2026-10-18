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
      region               = "europe-west1"
      cloud_run_cpu_quotas = { private = 16000 }
      workload_project_id  = "a-novel-production-prod"
      network = {
        network_id   = "projects/a-novel-production-prod/global/networks/agora-production"
        subnet_id    = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-europe-west1"
        network_tags = { genai = "agora-genai" }
      }
      database_hosts = {
        genai = {
          private_ip      = "10.20.0.8"
          port            = 5434
          service_account = "agora-genai-database@a-novel-production-prod.iam.gserviceaccount.com"
        }
      }
    }
  }
}

run "serves_privately_from_pinned_images_and_secrets" {
  command = plan

  assert {
    condition = alltrue([for service in [google_cloud_run_v2_service.grpc, google_cloud_run_v2_service.sweep] :
      service.ingress == "INGRESS_TRAFFIC_INTERNAL_ONLY" && !service.invoker_iam_disabled &&
      service.template[0].vpc_access[0].egress == "PRIVATE_RANGES_ONLY"
    ])
    error_message = "GenAI must stay internal and IAM-authenticated, reaching the database through the VPC and the provider through Google's managed egress."
  }

  assert {
    condition = alltrue([for image in [
      google_cloud_run_v2_service.grpc.template[0].containers[0].image,
      google_cloud_run_v2_service.sweep.template[0].containers[0].image,
      google_cloud_run_v2_job.migrations.template[0].template[0].containers[0].image,
      ] : can(regex("^europe-west1-docker\\.pkg\\.dev/a-novel-production-prod/agora-genai-private-production/service-genai/[a-z/]+@sha256:[a-f0-9]{64}$", image))
    ])
    error_message = "Workloads must run the Artifact Registry copy of each image, pinned by digest."
  }

  assert {
    condition = alltrue([for env in concat(
      tolist(google_cloud_run_v2_service.grpc.template[0].containers[0].env),
      tolist(google_cloud_run_v2_service.sweep.template[0].containers[0].env),
      tolist(google_cloud_run_v2_job.migrations.template[0].template[0].containers[0].env),
      ) : length(env.value_source) == 0 || can(regex("^[1-9][0-9]*$", env.value_source[0].secret_key_ref[0].version))
    ])
    error_message = "Secrets must be pinned to numeric versions, never latest."
  }

  assert {
    condition     = !contains([for env in google_cloud_run_v2_job.migrations.template[0].template[0].containers[0].env : env.name], "OPENAI_API_KEY")
    error_message = "Only the servers read the provider key."
  }

  assert {
    condition     = terraform_data.migrations.triggers_replace[0] == google_cloud_run_v2_job.migrations.template[0].template[0].containers[0].image
    error_message = "Migrations run during apply, once per image change."
  }

  assert {
    condition     = !contains([for env in google_cloud_run_v2_service.grpc.template[0].containers[0].env : env.name], "DOWNTIME_START")
    error_message = "Without a planned downtime, the service receives no start."
  }
}

run "rejects_an_unpinned_image" {
  command = plan

  variables {
    images = {
      grpc       = "ghcr.io/a-novel/service-genai/grpc:latest"
      migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.5.0@sha256:f5af5d12a188072da1e51ab51b5b2aef3c28be5941ed5b9dc48e0780d45bf453"
      sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.5.0@sha256:279ca54fb7c4b277056d15c1d26dc1930e07b19b9a2cce21f9542f23c6c63a07"
    }
  }

  expect_failures = [var.images]
}

run "passes_the_planned_downtime_start" {
  command = plan

  variables {
    downtime = "{\"components\":[\"service-genai.database\"],\"start\":\"2026-10-12T06:00:00Z\",\"end\":\"2026-10-12T07:00:00Z\"}"
  }

  assert {
    condition = alltrue([for container in concat(
      google_cloud_run_v2_service.grpc.template[0].containers,
      google_cloud_run_v2_service.sweep.template[0].containers,
      google_cloud_run_v2_job.migrations.template[0].template[0].containers,
      ) : lookup({ for env in container.env : env.name => env.value }, "DOWNTIME_START", null) == "2026-10-12T06:00:00Z"
    ])
    error_message = "Every service and job must receive the planned downtime start: the gRPC server and the sweep both write."
  }
}

run "ignores_another_services_downtime" {
  command = plan

  variables {
    downtime = "{\"components\":[\"service-json-keys.database\"],\"start\":\"2026-10-12T06:00:00Z\",\"end\":\"2026-10-12T07:00:00Z\"}"
  }

  assert {
    condition     = !contains([for env in google_cloud_run_v2_service.sweep.template[0].containers[0].env : env.name], "DOWNTIME_START")
    error_message = "A downtime that lists no GenAI component must leave GenAI alone."
  }
}
