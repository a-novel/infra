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
    POSTGRES_USER        = "agora_authentication_app"
    POSTGRES_DATABASE    = "agora_authentication"
    POSTGRES_TLS_ENABLED = "false"
  }
  # Registration and account emails, sent by the REST API and the maintenance job. The relay admits
  # them by the production NAT address, so they carry no SMTP credential.
  mail_env = {
    PLATFORM_AUTH_URL   = var.smtp.platform_auth_url
    SMTP_ADDR           = "${var.smtp.host}:587"
    SMTP_MAX_CONCURRENT = "8"
    SMTP_SENDER_EMAIL   = var.smtp.sender_email
    SMTP_SENDER_NAME    = var.smtp.sender_name
    # RFC 5321 gives each SMTP command minutes, and a fresh instance's first connection out waits
    # 30 seconds or more for Cloud NAT. No request waits for a send, and a job waits anyway.
    SMTP_TIMEOUT = "300s"
  }
  # The REST API and the jobs that share the maintenance image read the database password.
  maintenance_secret_env = {
    POSTGRES_PASSWORD = "app-password"
  }
  # The same workloads report their faults to Sentry; the migrations report nothing. Sentry names a
  # release <repository>@<version>, as release CI creates it, so it can resolve an issue in the
  # next release. Every image of a release carries its tag. The same workloads send their traces
  # and logs to the Sentry project over OTLP.
  # Each reporting workload also sets OTEL_RESOURCE_ATTRIBUTES to a_novel.workload=api when it serves
  # requests, or job when a person or a schedule starts it, so the Sentry dashboards and the latency
  # monitor read a request's duration apart from a job run's.
  sentry_env = {
    OTEL               = "true"
    SENTRY_ENVIRONMENT = "production"
    SENTRY_RELEASE     = "service-authentication@${trimprefix(local.images.rest.tag, "v")}"
    # A DSN is not a secret: Sentry documents it as safe to expose, and its public key only lets a
    # sender submit events. The OTLP header carries the same key.
    SENTRY_DSN                     = local.sentry.dsn
    OTEL_EXPORTER_OTLP_HEADERS     = local.sentry.otlp_headers
    OTEL_EXPORTER_OTLP_ENDPOINT    = "https://${local.foundation.sentry_ingest_host}/api/${local.sentry.project_id}/integration/otlp"
    OTEL_EXPORTER_OTLP_COMPRESSION = "gzip"
    OTEL_SERVICE_NAME              = "service-authentication"
  }
  rest_secret_env = merge(
    local.maintenance_secret_env,
    var.waitlist_url == null ? {} : { WAITLIST_SECRET = "waitlist-secret" },
  )
}

# Cloud Run names an execution after its job and token, and refuses a name it has used before. The
# token comes from this terraform_data's ID, which is new each time a trigger replaces it, even on a
# revert to an older image. Hashing fits the token into the 63-character execution name. A new
# database user is a trigger too, so the migration proves its login at once.
resource "terraform_data" "migrations" {
  triggers_replace = [local.image.migrations, local.database_env.POSTGRES_USER]
}

resource "google_cloud_run_v2_job" "migrations" {
  project             = local.private_project_id
  name                = "agora-authentication-migrations"
  location            = local.region
  deletion_protection = true
  labels              = { environment = "production", component = "authentication", role = "migrations" }

  # Apply runs the migration once per image change and fails until it succeeds.
  run_execution_token = substr(sha256(terraform_data.migrations.id), 0, 24)

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
          for_each = merge(local.database_env, local.downtime_env, {
            POSTGRES_MAX_OPEN_CONNS = "2"
            POSTGRES_MAX_IDLE_CONNS = "1"
          })
          content {
            name  = env.key
            value = env.value
          }
        }

        env {
          name = "POSTGRES_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = "projects/${local.management_project_id}/secrets/production-authentication-app-password"
              version = tostring(var.secret_versions["app-password"])
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

# Named humans run Authentication's one-time operations here, naming the operation in the
# execution's arguments, such as `account-role --email <address> --role auth:superadmin`. The stored
# job names none, so a run without arguments only prints the image's help. A failed run is not
# retried: the operator reads its log and runs it again, which the operations converge on.
resource "google_cloud_run_v2_job" "maintenance" {
  project             = local.private_project_id
  name                = "agora-authentication-maintenance"
  location            = local.region
  deletion_protection = true
  labels              = { environment = "production", component = "authentication", role = "maintenance" }

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = module.private_runtime.workloads["maintain"].service_account
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = "600s"
      max_retries           = 0

      containers {
        name  = "maintenance"
        image = local.image.maintenance

        dynamic "env" {
          for_each = merge(local.database_env, local.downtime_env, local.mail_env, local.sentry_env, {
            OTEL_RESOURCE_ATTRIBUTES = "a_novel.workload=job"
            POSTGRES_MAX_OPEN_CONNS  = "2"
            POSTGRES_MAX_IDLE_CONNS  = "1"
          })
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = local.maintenance_secret_env
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
        }
      }

      # All egress enters the VPC from the egress subnet, which Cloud NAT serves. The egress
      # allowlist lets only SMTP and Sentry out.
      vpc_access {
        egress = "ALL_TRAFFIC"
        network_interfaces {
          network    = local.network.network
          subnetwork = local.foundation.network.egress_subnet_id
          tags       = local.network.tags
        }
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Foundation's schedule runs this job to delete refresh token revocations past their expiry. The
# stored arguments name its one operation, so the schedule runs it without overrides. It shares the
# maintenance job's image and identity, which already read only the database password. A failed run
# is not retried: the next scheduled run deletes what it left.
resource "google_cloud_run_v2_job" "refresh_token_purge" {
  project             = local.private_project_id
  name                = "a-novel-authentication-refresh-token-purge"
  location            = local.region
  deletion_protection = true
  labels              = { environment = "production", component = "authentication", role = "refresh-token-purge" }

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = module.private_runtime.workloads["maintain"].service_account
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"
      timeout               = "600s"
      max_retries           = 0

      containers {
        name  = "refresh-token-purge"
        image = local.image.maintenance
        args  = ["refresh-token-purge"]

        dynamic "env" {
          for_each = merge(local.database_env, local.downtime_env, local.sentry_env, {
            OTEL_RESOURCE_ATTRIBUTES = "a_novel.workload=job"
            POSTGRES_MAX_OPEN_CONNS  = "2"
            POSTGRES_MAX_IDLE_CONNS  = "1"
          })
          content {
            name  = env.key
            value = env.value
          }
        }

        dynamic "env" {
          for_each = local.maintenance_secret_env
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
        }
      }

      # The job reports its failures to Sentry, so it runs on the egress subnet, where the egress
      # allowlist lets only Sentry out.
      vpc_access {
        egress = "ALL_TRAFFIC"
        network_interfaces {
          network    = local.network.network
          subnetwork = local.foundation.network.egress_subnet_id
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

# A revision that fails to start still records its template in state, so the next plan finds
# nothing to change while Cloud Run keeps serving the previous revision. Every plan replaces this
# terraform_data while the service's last rollout failed, and its new ID in the template makes Cloud
# Run roll the same configuration again.
resource "terraform_data" "rest_revision" {}

# Only the platform and the health checks may call the REST API, so it can trust the visitor IP the
# platform forwards. Their ID tokens name the custom audience, whatever the service URL.
resource "google_cloud_run_v2_service" "rest" {
  project              = local.api_project_id
  name                 = "agora-authentication-rest"
  location             = local.region
  ingress              = "INGRESS_TRAFFIC_ALL"
  invoker_iam_disabled = false
  custom_audiences     = ["agora-authentication-rest"]
  deletion_protection  = true
  labels               = { environment = "production", component = "authentication", role = "rest" }

  # Rate limits count in memory, so one instance sees every request. Needing a second one is the
  # trigger to move the counters to a shared store.
  scaling {
    min_instance_count = 1
    max_instance_count = 1
  }

  template {
    annotations                      = { revision-token = terraform_data.rest_revision.id }
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
        for_each = merge(local.database_env, local.downtime_env, local.mail_env, local.sentry_env, {
          OTEL_RESOURCE_ATTRIBUTES = "a_novel.workload=api"
          # One 64 MiB Argon2 hash at a time per vCPU: more slots add memory, not throughput.
          ARGON2_MAX_CONCURRENT = "1"
          GCLOUD_PROJECT_ID     = local.api_project_id
          # The Go runtime does not read the container's memory limit; this lets it reclaim one
          # hash's 64 MiB before the next one doubles the heap.
          GOMEMLIMIT              = "384MiB"
          POSTGRES_MAX_IDLE_CONNS = "5"
          POSTGRES_MAX_OPEN_CONNS = "10"
          REST_CLIENT_IP_HEADER   = "X-Client-IP"
          REST_PORT               = "8080"
          # Cloud Run kills the instance 10 seconds after SIGTERM, and the server then waits up to
          # 2 seconds each for Sentry and OpenTelemetry. A send still running at the deadline is cut.
          REST_TIMEOUT_SHUTDOWN  = "6s"
          SERVICE_JSON_KEYS_HOST = trimprefix(data.google_cloud_run_v2_service.json_keys.uri, "https://")
          SERVICE_JSON_KEYS_PORT = "443"
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
        cpu_idle = false
        # Startup computes a dummy hash; the boost shortens a rollout's overlap.
        startup_cpu_boost = true
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

    # All egress enters the VPC from the egress subnet, which Cloud NAT serves. The egress allowlist
    # lets only SMTP and Sentry out, and JSON Keys and the Telemetry API stay on the restricted VIP.
    vpc_access {
      egress = "ALL_TRAFFIC"
      network_interfaces {
        network    = local.network.network
        subnetwork = local.foundation.network.egress_subnet_id
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

    postcondition {
      condition     = (self.scaling[0].max_instance_count + 1) * tonumber(self.template[0].containers[0].resources[0].limits.cpu) * 1000 <= local.foundation.cloud_run_cpu_quotas["public-api"]
      error_message = "The maximum instances, plus one during a rollout, must fit the public-api Cloud Run CPU quota. Raise the quota in foundation first."
    }
  }
}

# Studio calls the REST API for its visitors, with a Google ID token for the custom audience.
resource "google_cloud_run_v2_service_iam_member" "platform_invoker" {
  project  = local.api_project_id
  name     = google_cloud_run_v2_service.rest.name
  location = local.region
  role     = "roles/run.servicesInvoker"
  member   = "serviceAccount:${data.terraform_remote_state.studio.outputs.service_account}"
}

# The deploy health check calls the REST API as the deploy identity.
resource "google_cloud_run_v2_service_iam_member" "health_invoker" {
  project  = local.api_project_id
  name     = google_cloud_run_v2_service.rest.name
  location = local.region
  role     = "roles/run.servicesInvoker"
  member   = "serviceAccount:${local.deployer}"
}

# The scheduled health check looks up the REST API's URL and calls it as its own identity, which
# only drift.yaml on master can mint.
resource "google_cloud_run_v2_service_iam_member" "scheduled_health" {
  for_each = toset(["roles/run.servicesInvoker", "roles/run.viewer"])

  project  = local.api_project_id
  name     = google_cloud_run_v2_service.rest.name
  location = local.region
  role     = each.value
  member   = "serviceAccount:infra-health@${local.management_project_id}.iam.gserviceaccount.com"
}
