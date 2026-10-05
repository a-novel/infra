variable "api" {
  description = "API revision and explicit traffic owner. Keep serving_revision on the healthy revision while checking the candidate, then promote with a separately reviewed plan."
  type = object({
    image            = string
    revision         = string
    serving_revision = string
  })
  default = null

  validation {
    condition     = var.api == null ? true : var.service == "json-keys" || var.zone == "public-api"
    error_message = "Private Authentication owns migration jobs only; its REST API belongs in public-api."
  }
  validation {
    condition = var.api == null ? true : can(regex(
      "^${replace(local.production_repository, ".", "\\.")}/service-${var.service}/${local.api_role}@sha256:[a-f0-9]{64}$", var.api.image,
    ))
    error_message = "Pin the selected service/zone's promoted API image by SHA-256 digest."
  }
  validation {
    condition = var.api == null ? true : alltrue([
      for revision in [var.api.revision, var.api.serving_revision] :
      length(revision) <= 63 && can(regex("^${local.api_name}-[a-z0-9]([a-z0-9-]*[a-z0-9])?$", revision))
    ])
    error_message = "Name exact revisions of this API; latest and peer revisions cannot own traffic."
  }
}

locals {
  api_role = var.zone == "public-api" ? "rest" : "grpc"
  api_name = "agora-${var.service}-${local.api_role}"
  api_secrets = merge(
    { POSTGRES_PASSWORD = "postgres-password" },
    local.api_role == "grpc" ? { APP_MASTER_KEY = "app-master-key" } : {},
    var.authentication == null ? {} : { SMTP_SENDER_PASSWORD = "smtp-sender-password" },
    try(var.authentication.waitlist_url, null) == null ? {} : { WAITLIST_SECRET = "waitlist-secret" },
  )
}

resource "google_cloud_run_v2_service" "api" {
  depends_on = [google_cloud_run_v2_job.application]
  count      = var.api == null ? 0 : 1

  project              = var.project_id
  location             = var.region
  name                 = local.api_name
  ingress              = local.api_role == "grpc" ? "INGRESS_TRAFFIC_INTERNAL_ONLY" : "INGRESS_TRAFFIC_ALL"
  invoker_iam_disabled = local.api_role == "rest"
  deletion_protection  = true
  labels               = { environment = "production", component = var.service, role = local.api_role }

  scaling {
    min_instance_count = var.zone == "public-api" && var.service == "json-keys" ? 0 : 1
    max_instance_count = 3
  }

  template {
    revision                         = var.api.revision
    service_account                  = try(local.coordinates.runtime.service_account, "")
    timeout                          = "60s"
    max_instance_request_concurrency = 20
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"

    containers {
      name  = local.api_role
      image = var.api.image

      ports {
        name           = local.api_role == "grpc" ? "h2c" : "http1"
        container_port = 8080
      }

      dynamic "env" {
        for_each = merge(local.database_environment, {
          GCLOUD_PROJECT_ID       = var.project_id
          OTEL                    = "true"
          POSTGRES_MAX_IDLE_CONNS = "10"
          POSTGRES_MAX_OPEN_CONNS = "20"
          }, local.api_role == "grpc" ? { GRPC_PORT = "8080" } : { REST_PORT = "8080" },
          var.authentication == null ? {} : local.authentication_environment,
        )
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.api_secrets
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
        # Authentication drains accepted email work after the HTTP response.
        cpu_idle          = var.service != "authentication"
        startup_cpu_boost = false
      }

      startup_probe {
        timeout_seconds   = 1
        period_seconds    = 3
        failure_threshold = 80

        dynamic "tcp_socket" {
          for_each = local.api_role == "grpc" ? [1] : []
          content { port = 8080 }
        }
        dynamic "http_get" {
          for_each = local.api_role == "rest" ? [1] : []
          content {
            path = "/v2/ping"
            port = 8080
          }
        }
      }

      dynamic "liveness_probe" {
        for_each = local.api_role == "rest" ? [1] : []
        content {
          timeout_seconds   = 1
          period_seconds    = 30
          failure_threshold = 3
          http_get {
            path = "/v2/ping"
            port = 8080
          }
        }
      }
    }

    vpc_access {
      egress = local.api_role == "grpc" ? "ALL_TRAFFIC" : "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = var.network.network
        subnetwork = var.network.subnetwork
        tags       = ["agora-${var.service}"]
      }
    }
  }

  traffic {
    type     = "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION"
    revision = var.api.serving_revision
    percent  = 100
    tag      = var.migration_image != null && var.api.revision == var.api.serving_revision ? "candidate" : null
  }

  dynamic "traffic" {
    for_each = var.api.revision == var.api.serving_revision ? [] : [var.api.revision]
    content {
      type     = "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION"
      revision = traffic.value
      percent  = 0
      tag      = "candidate"
    }
  }

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = terraform.workspace == "default"
      error_message = "Use the selected service's default workspace; another workspace could claim the same API."
    }
  }
}

output "api" {
  description = "Cloud Run's API and candidate endpoints. Health checks must succeed before changing the serving revision."
  value = var.api == null ? null : {
    name             = google_cloud_run_v2_service.api[0].name
    uri              = google_cloud_run_v2_service.api[0].uri
    revision         = var.api.revision
    serving_revision = var.api.serving_revision
    # Traffic status can lag a successful update; the declared tag owns this URL.
    candidate_uri = var.api.revision == var.api.serving_revision ? null : replace(google_cloud_run_v2_service.api[0].uri, "https://", "https://candidate---")
  }
}
