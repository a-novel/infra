locals {
  script = file("${path.module}/smoke.sh")
}

# A private service is unreachable from CI, so a one-shot job calls its status RPC from inside the
# VPC, as an identity that may only invoke it.
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  name     = var.target.name
  location = var.region
  role     = "roles/run.servicesInvoker"
  member   = "serviceAccount:${var.service_account}"
}

# Cloud Run names an execution after its job and token, and refuses a name it has used before, so
# the token comes from a terraform_data its triggers replace. The check runs on every new image,
# script or identity, and again once a planned downtime clears: the downtime skips it.
resource "terraform_data" "smoke" {
  triggers_replace = [var.image, var.downtime_start, sha256(local.script), var.service_account]
}

resource "google_cloud_run_v2_job" "smoke" {
  name                = "agora-${var.service}-smoke"
  location            = var.region
  deletion_protection = true
  labels              = { environment = "production", component = var.service, role = "smoke" }
  run_execution_token = substr(sha256(terraform_data.smoke.id), 0, 24)

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = var.service_account
      max_retries           = 0
      timeout               = "360s"
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

      containers {
        image   = var.image
        command = ["/bin/sh"]
        args    = ["-c", local.script]
        dynamic "env" {
          for_each = {
            PROTOCOL    = "grpc"
            SERVICE_URL = var.target.uri
            STATUS_RPC  = var.target.status_rpc
          }
          content {
            name  = env.key
            value = env.value
          }
        }
        dynamic "env" {
          for_each = var.downtime_start == "" ? {} : { DOWNTIME_START = var.downtime_start }
          content {
            name  = env.key
            value = env.value
          }
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
          tags       = var.network.tags
        }
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
