resource "google_cloud_run_v2_job" "verification" {
  count = var.migration_image != null && var.zone == "private" && var.service == "json-keys" && var.api != null ? 1 : 0

  project             = var.project_id
  location            = var.region
  name                = "agora-json-keys-smoke"
  deletion_protection = true
  labels              = { environment = "production", component = "json-keys", role = "smoke" }
  run_execution_token = substr(sha256(jsonencode(var.api)), 0, 24)

  template {
    task_count  = 1
    parallelism = 1
    template {
      service_account       = local.coordinates.runtime.service_account
      max_retries           = 0
      timeout               = "90s"
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      containers {
        image   = var.api.image
        command = ["/bin/sh"]
        args    = ["-c", file("${path.module}/../production/release/scripts/json-keys-smoke.sh")]
        env {
          name  = "JSON_KEYS_AUDIENCE"
          value = google_cloud_run_v2_service.api[0].uri
        }
        env {
          name  = "JSON_KEYS_CANDIDATE"
          value = replace(google_cloud_run_v2_service.api[0].uri, "https://", "https://candidate---")
        }
        resources {
          limits = { cpu = "1", memory = "512Mi" }
        }
      }
      vpc_access {
        egress = "ALL_TRAFFIC"
        network_interfaces {
          network    = var.network.network
          subnetwork = var.network.subnetwork
          tags       = ["agora-json-keys"]
        }
      }
    }
  }

  lifecycle { prevent_destroy = true }
}

import {
  for_each = var.adopt_existing_jobs && var.migration_image != null && var.zone == "private" && var.service == "json-keys" && var.api != null ? toset(["json-keys"]) : toset([])
  to       = google_cloud_run_v2_job.verification[0]
  id       = "projects/${var.project_id}/locations/${var.region}/jobs/agora-json-keys-smoke"
}
