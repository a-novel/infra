provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  job_contracts = {
    migrations = {
      timeout = "600s"
      retries = 0
      secrets = { POSTGRES_PASSWORD = "postgres-password" }
    }
    rotatekeys = {
      timeout = "300s"
      retries = 1
      secrets = { POSTGRES_PASSWORD = "postgres-password", APP_MASTER_KEY = "app-master-key" }
    }
  }
  jobs = { for role, contract in local.job_contracts : role => contract
    if var.zone != "public-api" && (role == "migrations" || var.service == "json-keys")
  }
  required_secrets = var.zone == "public-api" ? toset(concat(
    ["postgres-password"], var.service == "authentication" ? concat(
      ["smtp-sender-password"], try(var.authentication.waitlist_url, null) == null ? [] : ["waitlist-secret"],
    ) : [],
  )) : toset(flatten([for job in values(local.jobs) : values(job.secrets)]))
  database_user = "agora_${replace(var.service, "-", "_")}"
  database_environment = {
    POSTGRES_HOST        = try(local.coordinates.database.private_ip, "")
    POSTGRES_PORT        = try(tostring(local.coordinates.database.port), "")
    POSTGRES_USER        = local.database_user
    POSTGRES_DATABASE    = local.database_user
    POSTGRES_TLS_ENABLED = "false"
  }
}

resource "google_cloud_run_v2_job" "application" {
  for_each = local.jobs

  project             = var.project_id
  location            = var.region
  name                = "agora-${var.service}-${each.key}"
  deletion_protection = true
  labels              = { environment = "production", component = var.service, role = each.key }

  # Cloud Run keeps this job unready until the named execution completes.
  run_execution_token = each.key == "migrations" ? local.migration_token : null

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = try(local.coordinates.runtime.service_account, "")
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = each.value.timeout
      max_retries           = each.value.retries

      containers {
        name  = each.key
        image = lookup(var.images, each.key, "")

        dynamic "env" {
          for_each = local.database_environment
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = each.value.secrets
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = "projects/${var.management_project_id}/secrets/production-${var.service}-${env.value}"
                version = tostring(lookup(var.secret_versions, env.value, 0))
              }
            }
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
          tags       = ["agora-${var.service}"]
        }
      }
    }
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = terraform.workspace == "default"
      error_message = "Use the selected service's default workspace; another workspace could claim the same jobs."
    }
  }
}
