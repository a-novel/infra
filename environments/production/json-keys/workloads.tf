locals {
  images = { for role, ref in var.images : role => merge(
    regex("^ghcr\\.io/a-novel/(?P<path>[^:@]+):(?P<tag>[^@]+)@(?P<digest>sha256:[a-f0-9]{64})$", ref),
    { source = ref }
  ) }
  # Cloud Run pulls the copy that the deploy workflow places in Artifact Registry.
  image = { for role, image in local.images : role => "${module.runtime.repositories["production"]}/${image.path}@${image.digest}" }

  network = {
    network    = local.foundation.network.network_id
    subnetwork = local.foundation.network.subnet_id
    tags       = [local.foundation.network.network_tags["json_keys"]]
  }
  # A planned downtime listing one of this service's components stops it from its start, until
  # the downtime is removed.
  downtime     = try(jsondecode(var.downtime), null)
  downtime_env = anytrue([for component in try(local.downtime.components, []) : startswith(component, "service-json-keys.")]) ? { DOWNTIME_START = local.downtime.start } : {}
  database_env = {
    POSTGRES_HOST        = local.database.private_ip
    POSTGRES_PORT        = tostring(local.database.port)
    POSTGRES_USER        = "agora_json_keys"
    POSTGRES_DATABASE    = "agora_json_keys"
    POSTGRES_TLS_ENABLED = "false"
  }
  secret_env = {
    POSTGRES_PASSWORD = "postgres-password"
    APP_MASTER_KEY    = "app-master-key"
  }
  jobs = {
    migrations = { timeout = "600s", retries = 0, secrets = { POSTGRES_PASSWORD = "postgres-password" } }
    rotatekeys = { timeout = "300s", retries = 1, secrets = local.secret_env }
  }
}

resource "google_cloud_run_v2_job" "application" {
  for_each = local.jobs

  name                = "agora-json-keys-${each.key}"
  location            = local.region
  deletion_protection = true
  labels              = { environment = "production", component = "json-keys", role = each.key }

  # Apply runs the migration once per image and fails until it succeeds.
  run_execution_token = each.key == "migrations" ? substr(sha256(local.image.migrations), 0, 24) : null

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = module.runtime.service_account
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = each.value.timeout
      max_retries           = each.value.retries

      containers {
        name  = each.key
        image = local.image[each.key]

        dynamic "env" {
          for_each = merge(local.database_env, local.downtime_env)
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
                secret  = "projects/${local.management_project_id}/secrets/production-json-keys-${env.value}"
                version = tostring(var.secret_versions[env.value])
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
          network    = local.network.network
          subnetwork = local.network.subnetwork
          tags       = local.network.tags
        }
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_cloud_run_v2_service" "grpc" {
  name                 = "agora-json-keys-grpc"
  location             = local.region
  ingress              = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  invoker_iam_disabled = false
  deletion_protection  = true
  labels               = { environment = "production", component = "json-keys", role = "grpc" }

  scaling {
    min_instance_count = 1
    max_instance_count = 3
  }

  template {
    service_account                  = module.runtime.service_account
    timeout                          = "60s"
    max_instance_request_concurrency = 20
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"

    containers {
      name  = "grpc"
      image = local.image.grpc

      ports {
        name           = "h2c"
        container_port = 8080
      }

      dynamic "env" {
        for_each = merge(local.database_env, local.downtime_env, {
          GCLOUD_PROJECT_ID       = local.project_id
          GRPC_PORT               = "8080"
          OTEL                    = "true"
          POSTGRES_MAX_IDLE_CONNS = "10"
          POSTGRES_MAX_OPEN_CONNS = "20"
        })
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = "projects/${local.management_project_id}/secrets/production-json-keys-${env.value}"
              version = tostring(var.secret_versions[env.value])
            }
          }
        }
      }

      resources {
        limits            = { cpu = "1", memory = "512Mi" }
        cpu_idle          = true
        startup_cpu_boost = false
      }

      # Cloud Run moves traffic only to a revision whose startup probe passes.
      startup_probe {
        timeout_seconds   = 1
        period_seconds    = 3
        failure_threshold = 80
        tcp_socket {
          port = 8080
        }
      }
    }

    vpc_access {
      egress = "ALL_TRAFFIC"
      network_interfaces {
        network    = local.network.network
        subnetwork = local.network.subnetwork
        tags       = local.network.tags
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  # A new image serves traffic only after its migration succeeded.
  depends_on = [google_cloud_run_v2_job.application]

  lifecycle {
    prevent_destroy = true
  }
}

# The private service is unreachable from CI, so a one-shot job calls its
# health RPC from inside the VPC after every new image.
resource "google_cloud_run_v2_service_iam_member" "smoke_invoker" {
  name     = google_cloud_run_v2_service.grpc.name
  location = local.region
  role     = "roles/run.servicesInvoker"
  member   = module.runtime.member
}

resource "google_cloud_run_v2_job" "smoke" {
  name                = "agora-json-keys-smoke"
  location            = local.region
  deletion_protection = true
  labels              = { environment = "production", component = "json-keys", role = "smoke" }
  run_execution_token = substr(sha256(local.image.grpc), 0, 24)

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = module.runtime.service_account
      max_retries           = 0
      timeout               = "90s"
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

      containers {
        image   = local.image.grpc
        command = ["/bin/sh"]
        args    = ["-c", file("${path.module}/smoke.sh")]
        env {
          name  = "JSON_KEYS_URL"
          value = google_cloud_run_v2_service.grpc.uri
        }
        resources {
          limits = { cpu = "1", memory = "512Mi" }
        }
      }

      vpc_access {
        egress = "ALL_TRAFFIC"
        network_interfaces {
          network    = local.network.network
          subnetwork = local.network.subnetwork
          tags       = local.network.tags
        }
      }
    }
  }

  depends_on = [google_cloud_run_v2_service_iam_member.smoke_invoker]

  lifecycle {
    prevent_destroy = true
  }
}
