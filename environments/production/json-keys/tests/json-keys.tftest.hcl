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
      cloud_run_cpu_quotas = { private = 8000 }
      workload_project_id  = "a-novel-production-prod"
      network = {
        network_id   = "projects/a-novel-production-prod/global/networks/agora-production"
        subnet_id    = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-europe-west1"
        network_tags = { json_keys = "agora-json-keys" }
        # The subnet Cloud NAT serves.
        egress_subnet_id = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-egress-europe-west1"
      }
      database_hosts = {
        json_keys = {
          instance_group_manager = "agora-database-json-keys"
          private_ip             = "10.20.0.5"
          repository_ip          = "10.20.0.6"
          credentials_image      = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-json-keys-private-tooling/host-credentials@sha256:a5e264fc51c824c52fb6fd59b035e14e52fdc9f77e47b0375b352d8ad9bfd00d"
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
      alltrue([for vpc in [
        google_cloud_run_v2_service.grpc.template[0].vpc_access[0],
        google_cloud_run_v2_job.application["rotatekeys"].template[0].template[0].vpc_access[0],
        ] : vpc.egress == "ALL_TRAFFIC" && endswith(vpc.network_interfaces[0].subnetwork, "/agora-production-egress-europe-west1")
      ]) &&
      endswith(google_cloud_run_v2_job.application["migrations"].template[0].template[0].vpc_access[0].network_interfaces[0].subnetwork, "/agora-production-europe-west1")
    )
    error_message = "JSON Keys must stay internal and IAM-authenticated. The server's and the rotation job's egress goes through the egress subnet, whose NAT and allowlist decide what leaves; the migrations stay private."
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
      terraform_data.migrations.triggers_replace[0] == google_cloud_run_v2_job.application["migrations"].template[0].template[0].containers[0].image &&
      google_cloud_run_v2_job.application["rotatekeys"].run_execution_token == null
    )
    error_message = "Only migrations run during apply, once per image change."
  }

  assert {
    condition     = !contains([for env in google_cloud_run_v2_service.grpc.template[0].containers[0].env : env.name], "DOWNTIME_START")
    error_message = "Without a planned downtime, the service receives no start."
  }

  assert {
    condition = alltrue([for container in [
      google_cloud_run_v2_service.grpc.template[0].containers[0],
      google_cloud_run_v2_job.application["rotatekeys"].template[0].template[0].containers[0],
      ] : can(regex("^service-json-keys@[0-9]+\\.[0-9]+\\.[0-9]+$", { for env in container.env : env.name => env.value }["SENTRY_RELEASE"]))
    ])
    error_message = "Every reporting workload names its release <repository>@<semver>, as release CI creates it in Sentry."
  }

  assert {
    condition     = google_cloud_run_v2_service.grpc.template[0].containers[0].resources[0].cpu_idle == false
    error_message = "JSON Keys keeps CPU between requests, so its Sentry events and spans leave."
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

run "passes_the_planned_downtime_start" {
  command = plan

  variables {
    downtime = "{\"components\":[\"service-json-keys.database\"],\"start\":\"2026-10-12T06:00:00Z\",\"end\":\"2026-10-12T07:00:00Z\"}"
  }

  assert {
    condition = alltrue([for container in concat(
      google_cloud_run_v2_service.grpc.template[0].containers,
      flatten([for job in google_cloud_run_v2_job.application : job.template[0].template[0].containers]),
      ) : lookup({ for env in container.env : env.name => env.value }, "DOWNTIME_START", null) == "2026-10-12T06:00:00Z"
    ])
    error_message = "Every service and application job must receive the planned downtime start."
  }
}

run "ignores_another_services_downtime" {
  command = plan

  variables {
    downtime = "{\"components\":[\"service-authentication.database\"],\"start\":\"2026-10-12T06:00:00Z\",\"end\":\"2026-10-12T07:00:00Z\"}"
  }

  assert {
    condition     = !contains([for env in google_cloud_run_v2_service.grpc.template[0].containers[0].env : env.name], "DOWNTIME_START")
    error_message = "A downtime that lists no JSON Keys component must leave JSON Keys alone."
  }
}

run "rejects_a_malformed_downtime_window" {
  command = plan

  variables {
    downtime = "json-keys"
  }

  expect_failures = [var.downtime]
}
