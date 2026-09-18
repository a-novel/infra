resource "google_cloud_run_v2_job" "probe" {
  project             = var.project_id
  location            = var.region
  name                = "${var.name}-verify"
  deletion_protection = true

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = var.probe.service_account
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = "90s"
      max_retries           = 0

      containers {
        name  = "probe"
        image = var.verification_image
        args  = ["probe"]

        resources {
          limits = { cpu = "1", memory = "256Mi" }
        }
      }

      vpc_access {
        egress = "ALL_TRAFFIC"
        network_interfaces {
          network    = var.probe.network
          subnetwork = var.probe.subnetwork
          # This tag receives only restricted Google API HTTPS egress, never PostgreSQL.
          tags = ["agora-rollout-probe"]
        }
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
