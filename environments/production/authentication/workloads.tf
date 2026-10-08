locals {
  images = { for role, ref in var.images : role => merge(
    regex("^ghcr\\.io/a-novel/(?P<path>[^:@]+):(?P<tag>[^@]+)@(?P<digest>sha256:[a-f0-9]{64})$", ref),
    { source = ref, runtime = role == "rest" ? module.api_runtime : module.private_runtime }
  ) }
  # Cloud Run pulls the copy that the deploy workflow places in Artifact Registry.
  image = { for role, image in local.images : role => "${image.runtime.repositories["production"]}/${image.path}@${image.digest}" }

  network = {
    network    = local.foundation.network.network_id
    subnetwork = local.foundation.network.subnet_id
    tags       = [local.foundation.network.network_tags["authentication"]]
  }
  # A planned downtime listing one of this service's components stops it from its start, until
  # the downtime is removed.
  downtime     = try(jsondecode(var.downtime), null)
  downtime_env = anytrue([for component in try(local.downtime.components, []) : startswith(component, "service-authentication.")]) ? { DOWNTIME_START = local.downtime.start } : {}
  database_env = {
    POSTGRES_HOST        = local.database.private_ip
    POSTGRES_PORT        = tostring(local.database.port)
    POSTGRES_USER        = "agora_authentication"
    POSTGRES_DATABASE    = "agora_authentication"
    POSTGRES_TLS_ENABLED = "false"
  }
  rest_secret_env = merge(
    { POSTGRES_PASSWORD = "postgres-password", SMTP_SENDER_PASSWORD = "smtp-sender-password" },
    var.waitlist_url == null ? {} : { WAITLIST_SECRET = "waitlist-secret" },
  )
}

resource "google_cloud_run_v2_job" "migrations" {
  project             = local.private_project_id
  name                = "agora-authentication-migrations"
  location            = local.region
  deletion_protection = true
  labels              = { environment = "production", component = "authentication", role = "migrations" }

  # Apply runs the migration once per image and fails until it succeeds.
  run_execution_token = substr(sha256(local.image.migrations), 0, 24)

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = module.private_runtime.service_account
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = "600s"
      max_retries           = 0

      containers {
        name  = "migrations"
        image = local.image.migrations

        dynamic "env" {
          for_each = merge(local.database_env, local.downtime_env)
          content {
            name  = env.key
            value = env.value
          }
        }

        env {
          name = "POSTGRES_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = "projects/${local.management_project_id}/secrets/production-authentication-postgres-password"
              version = tostring(var.secret_versions["postgres-password"])
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

# Authentication calls the private JSON Keys service over Cloud Run's internal ingress.
data "google_cloud_run_v2_service" "json_keys" {
  project  = local.private_project_id
  name     = "agora-json-keys-grpc"
  location = local.region
}

resource "google_cloud_run_v2_service_iam_member" "json_keys_invoker" {
  project  = local.private_project_id
  name     = data.google_cloud_run_v2_service.json_keys.name
  location = local.region
  role     = "roles/run.servicesInvoker"
  member   = module.api_runtime.member
}

resource "google_cloud_run_v2_service" "rest" {
  project              = local.api_project_id
  name                 = "agora-authentication-rest"
  location             = local.region
  ingress              = "INGRESS_TRAFFIC_ALL"
  invoker_iam_disabled = true
  deletion_protection  = true
  labels               = { environment = "production", component = "authentication", role = "rest" }

  scaling {
    min_instance_count = 1
    max_instance_count = 3
  }

  template {
    service_account                  = module.api_runtime.service_account
    timeout                          = "60s"
    max_instance_request_concurrency = 20
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"

    containers {
      name  = "rest"
      image = local.image.rest

      ports {
        name           = "http1"
        container_port = 8080
      }

      dynamic "env" {
        for_each = merge(local.database_env, local.downtime_env, {
          GCLOUD_PROJECT_ID       = local.api_project_id
          OTEL                    = "true"
          PLATFORM_AUTH_URL       = var.smtp.platform_auth_url
          POSTGRES_MAX_IDLE_CONNS = "10"
          POSTGRES_MAX_OPEN_CONNS = "20"
          REST_PORT               = "8080"
          REST_TIMEOUT_SHUTDOWN   = "9s"
          SERVICE_JSON_KEYS_HOST  = trimprefix(data.google_cloud_run_v2_service.json_keys.uri, "https://")
          SERVICE_JSON_KEYS_PORT  = "443"
          SMTP_ADDR               = "${var.smtp.host}:587"
          SMTP_MAX_CONCURRENT     = "8"
          SMTP_SENDER_DOMAIN      = var.smtp.host
          SMTP_SENDER_EMAIL       = var.smtp.sender_email
          SMTP_SENDER_NAME        = var.smtp.sender_name
          SMTP_TIMEOUT            = "5s"
          SMTP_USERNAME           = var.smtp.username
          }, var.waitlist_url == null ? {} : {
          WAITLIST_URL = var.waitlist_url
        })
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.rest_secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = "projects/${local.management_project_id}/secrets/production-authentication-${env.value}"
              version = tostring(var.secret_versions[env.value])
            }
          }
        }
      }

      resources {
        limits = { cpu = "1", memory = "512Mi" }
        # Accepted email keeps sending after the HTTP response returns.
        cpu_idle          = false
        startup_cpu_boost = false
      }

      # Cloud Run moves traffic only to a revision whose startup probe passes.
      startup_probe {
        timeout_seconds   = 1
        period_seconds    = 3
        failure_threshold = 80
        http_get {
          path = "/v2/ping"
          port = 8080
        }
      }

      liveness_probe {
        timeout_seconds   = 1
        period_seconds    = 30
        failure_threshold = 3
        http_get {
          path = "/v2/ping"
          port = 8080
        }
      }
    }

    # Private ranges reach the database and JSON Keys; SMTP leaves through Google's managed egress.
    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
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
  depends_on = [google_cloud_run_v2_job.migrations]

  lifecycle {
    prevent_destroy = true
  }
}
