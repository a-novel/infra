locals {
  images = { for role, ref in var.images : role => merge(
    regex("^ghcr\\.io/a-novel/(?P<path>[^:@]+):(?P<tag>[^@]+)@(?P<digest>sha256:[a-f0-9]{64})$", ref),
    { source = ref }
  ) }
  # Cloud Run pulls the copy that the deploy workflow places in Artifact Registry.
  image = { for role, image in local.images : role => "${module.runtime.repositories["production"]}/${image.path}@${image.digest}" }

  # The server's spans go to the platform's Sentry project over OTLP, and the server runs no Sentry
  # SDK, so it sets no SENTRY_* variable. The browser's SDK reads the public DSN once the visitor
  # consents; a DSN is not a secret.
  otel_env = {
    PUBLIC_SENTRY_DSN              = local.sentry.dsn
    OTEL                           = "true"
    OTEL_EXPORTER_OTLP_HEADERS     = local.sentry.otlp_headers
    OTEL_EXPORTER_OTLP_ENDPOINT    = "https://${local.foundation.sentry_ingest_host}/api/${local.sentry.project_id}/integration/otlp"
    OTEL_EXPORTER_OTLP_COMPRESSION = "gzip"
    OTEL_SERVICE_NAME              = "platform-studio"
    OTEL_RESOURCE_ATTRIBUTES       = "a_novel.workload=api"
  }
}

# A revision that fails to start still records its template in state, so the next plan finds
# nothing to change while Cloud Run keeps serving the previous revision. Every plan replaces this
# terraform_data while the service's last rollout failed, and its new ID in the template makes Cloud
# Run roll the same configuration again.
resource "terraform_data" "web_revision" {}

# Visitors reach Studio only through the load balancer, which carries no identity, so the service
# admits every request the load balancer forwards and no other.
resource "google_cloud_run_v2_service" "web" {
  project              = local.project_id
  name                 = "agora-studio-web"
  location             = local.region
  ingress              = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  invoker_iam_disabled = true
  deletion_protection  = true
  labels               = { environment = "production", component = "studio", role = "web" }

  scaling {
    min_instance_count = 0
    max_instance_count = 2
  }

  template {
    annotations                      = { revision-token = terraform_data.web_revision.id }
    service_account                  = module.runtime.service_account
    timeout                          = "60s"
    max_instance_request_concurrency = 80
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"

    containers {
      name  = "web"
      image = local.image.web

      ports {
        name           = "http1"
        container_port = 3000
      }

      dynamic "env" {
        for_each = merge(local.otel_env, {
          AUTHENTICATION_SERVICE_URL      = data.google_cloud_run_v2_service.authentication.uri
          AUTHENTICATION_SERVICE_AUDIENCE = "agora-authentication-rest"
          # The load balancer appends the visitor's address and its own, so the visitor is second
          # from the right. Authentication rate-limits by the address Studio forwards.
          ADDRESS_HEADER = "X-Forwarded-For"
          XFF_DEPTH      = "2"
          # Form posts must come from the domain; SvelteKit compares their Origin with this.
          ORIGIN = "https://${var.domain}"
          # Cloud Run kills the instance 10 seconds after SIGTERM. adapter-node flushes the spans
          # only once its drain ends, so the drain stops at 5 seconds.
          SHUTDOWN_TIMEOUT = "5"
        })
        content {
          name  = env.key
          value = env.value
        }
      }

      resources {
        limits = { cpu = "1", memory = "512Mi" }
        # The spans of a request export after its response, from a background batch.
        cpu_idle          = false
        startup_cpu_boost = true
      }

      # Cloud Run moves traffic only to a revision whose startup probe passes.
      startup_probe {
        timeout_seconds   = 1
        period_seconds    = 3
        failure_threshold = 20
        http_get {
          path = "/ping"
          port = 3000
        }
      }

      liveness_probe {
        timeout_seconds   = 1
        period_seconds    = 30
        failure_threshold = 3
        http_get {
          path = "/ping"
          port = 3000
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  lifecycle {
    prevent_destroy = true

    postcondition {
      condition     = (self.scaling[0].max_instance_count + 1) * tonumber(self.template[0].containers[0].resources[0].limits.cpu) * 1000 <= local.foundation.cloud_run_cpu_quotas["public"]
      error_message = "The maximum instances, plus one during a rollout, must fit the public Cloud Run CPU quota. Raise the quota in foundation first."
    }
  }
}
