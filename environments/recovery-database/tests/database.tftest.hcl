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
  recovery = { project = "a-novel-recovery-261101", service = "genai", target_time = "2026-10-30T12:00:00Z" }
}

run "restores_production_backups_read_only" {
  command = plan

  assert {
    condition = (
      kubernetes_manifest.database.manifest.spec.bootstrap.recovery.source == "production" &&
      kubernetes_manifest.database.manifest.spec.bootstrap.recovery.recoveryTarget.targetTime == "2026-10-30T12:00:00Z" &&
      one(kubernetes_manifest.database.manifest.spec.externalClusters).plugin.parameters.serverName == local.production.backup_server_name &&
      !can(kubernetes_manifest.database.manifest.spec.plugins) &&
      kubernetes_manifest.backups.manifest.spec.configuration.destinationPath == "gs://a-novel-management-prod-232403541574-barman-genai/"
    )
    error_message = "The drill must recover from the service's production backups, under their archive name, to the target time, and archive nothing."
  }

  assert {
    condition = (
      startswith(one(kubernetes_manifest.image.manifest.spec.images).image, "europe-west9-docker.pkg.dev/a-novel-recovery-261101/ghcr-io/a-novel/service-genai/database:") &&
      endswith(one(kubernetes_manifest.image.manifest.spec.images).image, split("@", local.release_image)[1]) &&
      contains(kubernetes_manifest.database.manifest.spec.postgresql.shared_preload_libraries, "pg_cron")
    )
    error_message = "The drill must run production's release image, through its own cache, with production's settings."
  }
}

run "recovers_to_the_latest_without_a_target" {
  command = plan

  variables {
    recovery = { project = "a-novel-recovery-261101", service = "json-keys" }
  }

  assert {
    condition = (
      !can(kubernetes_manifest.database.manifest.spec.bootstrap.recovery.recoveryTarget) &&
      length(kubernetes_manifest.database.manifest.spec.postgresql.shared_preload_libraries) == 0
    )
    error_message = "Without a target time, the drill must recover to the latest WAL."
  }
}
