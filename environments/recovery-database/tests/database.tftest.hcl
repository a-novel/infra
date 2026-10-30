# Plans production's committed inputs against mocked providers and the drill's mocked outputs.
mock_provider "google" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}

override_data {
  target = data.terraform_remote_state.drill
  values = {
    outputs = {
      cluster = {
        dns_endpoint = "gke-mock.europe-west9-a.gke.goog"
        image_registries = {
          "ghcr.io" = "europe-west9-docker.pkg.dev/a-novel-recovery-261101/ghcr-io"
          "quay.io" = "europe-west9-docker.pkg.dev/a-novel-recovery-261101/quay-io"
        }
      }
    }
  }
}

override_data {
  target = data.terraform_remote_state.bootstrap
  values = {
    outputs = {
      barman_buckets = {
        authentication = "a-novel-management-prod-232403541574-barman-authentication"
        genai          = "a-novel-management-prod-232403541574-barman-genai"
        json-keys      = "a-novel-management-prod-232403541574-barman-json-keys"
      }
    }
  }
}

variables {
  recovery = { project = "a-novel-recovery-261101", target_time = "2026-10-30T12:00:00Z" }
}

run "restores_every_database_from_its_production_backups_read_only" {
  command = plan

  assert {
    condition = alltrue([for service in ["authentication", "genai", "json-keys"] : (
      kubernetes_manifest.database[service].manifest.spec.bootstrap.recovery.source == "production" &&
      kubernetes_manifest.database[service].manifest.spec.bootstrap.recovery.recoveryTarget.targetTime == "2026-10-30T12:00:00Z" &&
      one(kubernetes_manifest.database[service].manifest.spec.externalClusters).plugin.parameters.serverName == local.production.backup_server_name &&
      !can(kubernetes_manifest.database[service].manifest.spec.plugins) &&
      kubernetes_manifest.backups[service].manifest.spec.configuration.destinationPath == "gs://a-novel-management-prod-232403541574-barman-${service}/"
    )])
    error_message = "Each database must recover from its own service's production backups, under their archive name, to the target time, and archive nothing."
  }

  assert {
    condition = (
      startswith(one(kubernetes_manifest.image["genai"].manifest.spec.images).image, "europe-west9-docker.pkg.dev/a-novel-recovery-261101/ghcr-io/a-novel/service-genai/database:") &&
      endswith(one(kubernetes_manifest.image["genai"].manifest.spec.images).image, split("@", local.database_images["genai"])[1]) &&
      contains(kubernetes_manifest.database["genai"].manifest.spec.postgresql.shared_preload_libraries, "pg_cron") &&
      length(kubernetes_manifest.database["json-keys"].manifest.spec.postgresql.shared_preload_libraries) == 0
    )
    error_message = "Each drill must run its service's release image, through its own cache, with production's settings."
  }
}

run "checks_every_restored_database" {
  command = plan

  assert {
    condition = (
      keys(kubernetes_job_v1.check) == keys(kubernetes_manifest.database) &&
      alltrue([for check in kubernetes_job_v1.check : check.wait_for_completion && check.spec[0].backoff_limit == 0])
    )
    error_message = "Each restored database must pass its check once for the apply to succeed."
  }

  assert {
    condition = (
      strcontains(kubernetes_job_v1.check["genai"].spec[0].template[0].spec[0].container[0].command[4], "cron.job") &&
      !strcontains(kubernetes_job_v1.check["json-keys"].spec[0].template[0].spec[0].container[0].command[4], "cron.job")
    )
    error_message = "Only a database that runs pg_cron must bring its schedules back."
  }
}

run "recovers_the_selected_services_to_the_latest_without_a_target" {
  command = plan

  variables {
    recovery = { project = "a-novel-recovery-261101", services = ["json-keys"] }
  }

  assert {
    condition = (
      keys(kubernetes_manifest.database) == ["json-keys"] &&
      !can(kubernetes_manifest.database["json-keys"].manifest.spec.bootstrap.recovery.recoveryTarget)
    )
    error_message = "Without a target time, the drill must recover only the selected services, to the latest WAL."
  }
}
