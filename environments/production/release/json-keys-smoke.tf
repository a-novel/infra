# Reuse the shipped grpcurl and the JSON Keys runtime identity.
# No credentials are mounted, no scheduler invokes it, and recovery omits it.
resource "google_cloud_run_v2_job" "json_keys_smoke" {
  count = var.application_release == null || var.recovery_mode ? 0 : 1

  project             = var.workload_project_id
  location            = var.region
  name                = "agora-json-keys-smoke"
  deletion_protection = false
  labels              = merge(local.labels, { component = "json-keys", role = "smoke" })

  template {
    task_count  = 1
    parallelism = 1
    template {
      service_account       = var.runtime_service_accounts.json_keys
      max_retries           = 0
      timeout               = "90s"
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      containers {
        image   = var.application_release.json_keys.images.grpc
        command = ["/bin/sh"]
        args    = ["-c", file("${path.module}/scripts/json-keys-smoke.sh")]
        env {
          name  = "JSON_KEYS_AUDIENCE"
          value = google_cloud_run_v2_service.json_keys[0].uri
        }
        env {
          name  = "JSON_KEYS_CANDIDATE"
          value = replace(google_cloud_run_v2_service.json_keys[0].uri, "https://", "https://candidate---")
        }
        resources {
          limits = { cpu = "1", memory = "512Mi" }
        }
      }
      vpc_access {
        egress = "ALL_TRAFFIC"
        network_interfaces {
          network    = var.network_id
          subnetwork = var.subnet_id
          tags       = ["agora-json-keys"]
        }
      }
    }
  }
}

resource "google_tags_location_tag_binding" "json_keys_smoke" {
  count = length(google_cloud_run_v2_job.json_keys_smoke)

  parent    = "//run.googleapis.com/projects/${var.workload_project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.json_keys_smoke[0].name}"
  location  = var.region
  tag_value = var.cloud_run_invocation_tags.values.release
  lifecycle {
    replace_triggered_by = [google_cloud_run_v2_job.json_keys_smoke[count.index].uid]
  }
}
