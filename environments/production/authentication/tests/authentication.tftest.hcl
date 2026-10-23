mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email  = "agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
      member = "serviceAccount:agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
      name   = "projects/a-novel-production-prod/serviceAccounts/agora-mock@a-novel-production-prod.iam.gserviceaccount.com"
    }
  }
  mock_data "google_cloud_run_v2_service" {
    defaults = { uri = "https://agora-json-keys-grpc-test-ew.a.run.app" }
  }
}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      region               = "europe-west1"
      cloud_run_cpu_quotas = { private = 8000, "public-api" = 2000 }
      production_projects = {
        private      = { project_id = "a-novel-production-prod" }
        "public-api" = { project_id = "a-novel-public-api-prod" }
      }
      network = {
        network_id   = "projects/a-novel-production-prod/global/networks/agora-production"
        subnet_id    = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-europe-west1"
        network_tags = { authentication = "agora-authentication" }
        # The subnet Cloud NAT serves.
        egress_subnet_id = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-egress-europe-west1"
      }
      database_hosts = {
        authentication = {
          instance_group_manager = "agora-database-authentication"
          private_ip             = "10.20.0.4"
          repository_ip          = "10.20.0.7"
          credentials_image      = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-authentication-private-tooling/host-credentials@sha256:a5e264fc51c824c52fb6fd59b035e14e52fdc9f77e47b0375b352d8ad9bfd00d"
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
      google_logging_project_exclusion.successful_healthchecks.project == google_cloud_run_v2_service.rest.project &&
      strcontains(google_logging_project_exclusion.successful_healthchecks.filter, "httpRequest.status<400")
    )
    error_message = "Only successful health checks are excluded, in the project the REST service runs in."
  }

  assert {
    condition = (
      google_cloud_run_v2_job.migrations.project == "a-novel-production-prod" &&
      google_cloud_run_v2_service.rest.project == "a-novel-public-api-prod" &&
      google_cloud_run_v2_service.rest.ingress == "INGRESS_TRAFFIC_ALL" &&
      alltrue([for vpc in [google_cloud_run_v2_service.rest.template[0].vpc_access[0], google_cloud_run_v2_job.maintenance.template[0].template[0].vpc_access[0]] :
        vpc.egress == "ALL_TRAFFIC" && endswith(vpc.network_interfaces[0].subnetwork, "/agora-production-egress-europe-west1")
      ])
    )
    error_message = "Migrations stay private; only the REST API is public. Its egress and the maintenance job's go through the egress subnet, whose NAT and allowlist decide what leaves."
  }

  assert {
    condition = (
      !google_cloud_run_v2_service.rest.invoker_iam_disabled &&
      lookup({ for env in google_cloud_run_v2_service.rest.template[0].containers[0].env : env.name => env.value }, "REST_CLIENT_IP_HEADER", null) == "X-Client-IP" &&
      !contains([for env in google_cloud_run_v2_service.rest.template[0].containers[0].env : env.name], "REST_RATE_LIMITS_ENABLED")
    )
    error_message = "Only IAM-admitted callers may reach the REST API, since it trusts their visitor IP header, and its rate limits always stay on."
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

  assert {
    condition = (
      google_cloud_run_v2_job.maintenance.project == "a-novel-production-prod" &&
      google_cloud_run_v2_job.maintenance.run_execution_token == null &&
      length(coalesce(google_cloud_run_v2_job.maintenance.template[0].template[0].containers[0].args, [])) == 0 &&
      google_cloud_run_v2_job.maintenance.template[0].template[0].max_retries == 0 &&
      toset([for env in google_cloud_run_v2_job.maintenance.template[0].template[0].containers[0].env : env.name if length(env.value_source) > 0]) == toset(["POSTGRES_PASSWORD"])
    )
    error_message = "The maintenance job stays private, runs only when a human starts it with an operation, and mounts only the database password."
  }
}

run "requires_the_waitlist_secret_with_its_url" {
  command = plan

  variables {
    waitlist_url = "https://example.com/waitlist"
  }

  expect_failures = [var.secret_versions]
}

run "passes_the_planned_downtime_start" {
  command = plan

  variables {
    downtime = "{\"components\":[\"service-json-keys.database\",\"service-authentication.database\"],\"start\":\"2026-10-12T06:00:00Z\",\"end\":\"2026-10-12T07:00:00Z\"}"
  }

  assert {
    condition = alltrue([for container in concat(
      google_cloud_run_v2_service.rest.template[0].containers,
      google_cloud_run_v2_job.migrations.template[0].template[0].containers,
      google_cloud_run_v2_job.maintenance.template[0].template[0].containers,
      ) : lookup({ for env in container.env : env.name => env.value }, "DOWNTIME_START", null) == "2026-10-12T06:00:00Z"
    ])
    error_message = "The REST API and both jobs must receive the planned downtime start."
  }
}

run "ignores_another_services_downtime" {
  command = plan

  variables {
    downtime = "{\"components\":[\"service-json-keys.database\"],\"start\":\"2026-10-12T06:00:00Z\",\"end\":\"2026-10-12T07:00:00Z\"}"
  }

  assert {
    condition     = !contains([for env in google_cloud_run_v2_service.rest.template[0].containers[0].env : env.name], "DOWNTIME_START")
    error_message = "A downtime that lists no Authentication component must leave Authentication alone."
  }
}

run "refuses_instances_beyond_the_quota" {
  command = plan

  override_data {
    target = data.terraform_remote_state.foundation
    values = {
      outputs = {
        region               = "europe-west1"
        cloud_run_cpu_quotas = { private = 8000, "public-api" = 1000 }
        production_projects = {
          private      = { project_id = "a-novel-production-prod" }
          "public-api" = { project_id = "a-novel-public-api-prod" }
        }
        network = {
          network_id   = "projects/a-novel-production-prod/global/networks/agora-production"
          subnet_id    = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-europe-west1"
          network_tags = { authentication = "agora-authentication" }
          # The subnet Cloud NAT serves.
          egress_subnet_id = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-egress-europe-west1"
        }
        database_hosts = {
          authentication = {
            instance_group_manager = "agora-database-authentication"
            private_ip             = "10.20.0.4"
            repository_ip          = "10.20.0.7"
            credentials_image      = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-authentication-private-tooling/host-credentials@sha256:a5e264fc51c824c52fb6fd59b035e14e52fdc9f77e47b0375b352d8ad9bfd00d"
            port                   = 5433
            service_account        = "agora-auth-database@a-novel-production-prod.iam.gserviceaccount.com"
            zone                   = "europe-west1-d"
          }
        }
      }
    }
  }

  expect_failures = [google_cloud_run_v2_service.rest]
}
