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
    tags       = [local.foundation.network.network_tags["genai"]]
  }
  # A planned downtime listing one of this service's components stops it from its start, until
  # the downtime is removed.
  downtime     = try(jsondecode(var.downtime), null)
  downtime_env = anytrue([for component in try(local.downtime.components, []) : startswith(component, "service-genai.")]) ? { DOWNTIME_START = local.downtime.start } : {}
  database_env = {
    POSTGRES_HOST        = local.database.private_ip
    POSTGRES_PORT        = tostring(local.database.port)
    POSTGRES_USER        = "agora_genai_app"
    POSTGRES_DATABASE    = "agora_genai"
    POSTGRES_TLS_ENABLED = "false"
  }
  # The servers call the provider, so both read its key. The migrations job reads only the database.
  migrations_secret_env = { POSTGRES_PASSWORD = "app-password" }
  server_secret_env = {
    POSTGRES_PASSWORD = "app-password"
    OPENAI_API_KEY    = "openai-api-key"
  }
  server_env = merge(local.database_env, local.downtime_env, {
    OTEL               = "true"
    SENTRY_ENVIRONMENT = "production"
    # Sentry names a release <repository>@<version>, as release CI creates it, so it can resolve an
    # issue in the next release. Every image of a release carries its tag.
    SENTRY_RELEASE = "service-genai@${trimprefix(local.images.grpc.tag, "v")}"
    # The servers send their traces and logs to the Sentry project over OTLP.
    OTEL_EXPORTER_OTLP_ENDPOINT = "https://${local.foundation.sentry_ingest_host}/api/${local.sentry.project_id}/integration/otlp"
    # A DSN is not a secret: Sentry documents it as safe to expose, and its public key only lets a
    # sender submit events. The OTLP header carries the same key.
    SENTRY_DSN                     = local.sentry.dsn
    OTEL_EXPORTER_OTLP_HEADERS     = local.sentry.otlp_headers
    OTEL_EXPORTER_OTLP_COMPRESSION = "gzip"
    OTEL_SERVICE_NAME              = "service-genai"
  })
}

# Cloud Run names an execution after its job and token, and refuses a name it has used before. The
# token comes from this terraform_data's ID, which is new each time a trigger replaces it, even on a
# revert to an older image. Hashing fits the token into the 63-character execution name. A new
# identity or database user is a trigger too, so the migration proves its grants and login at once.
resource "terraform_data" "migrations" {
  triggers_replace = [local.image.migrations, module.runtime.workloads["migrations"].service_account, local.database_env.POSTGRES_USER]
}

resource "google_cloud_run_v2_job" "migrations" {
  name                = "agora-genai-migrations"
  location            = local.region
  deletion_protection = true
  labels              = { environment = "production", component = "genai", role = "migrations" }

  # Apply runs the migration once per image change and fails until it succeeds. It also schedules
  # the retention purge through pg_cron.
  run_execution_token = substr(sha256(terraform_data.migrations.id), 0, 24)

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = module.runtime.workloads["migrations"].service_account
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

        dynamic "env" {
          for_each = local.migrations_secret_env
          content {
            name = env.key
            value_source {
              secret_key_ref {
                secret  = "projects/${local.management_project_id}/secrets/production-genai-${env.value}"
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
  name                 = "agora-genai-grpc"
  location             = local.region
  ingress              = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  invoker_iam_disabled = false
  deletion_protection  = true
  labels               = { environment = "production", component = "genai", role = "grpc" }

  # Each open GenerationStream holds one of an instance's 20 request slots, so streams scale out.
  # TODO: keep one warm instance once narrative-engine calls this service.
  scaling {
    min_instance_count = 0
    max_instance_count = 4
  }

  template {
    service_account = module.runtime.service_account
    # A check can outlast a minute: a streamed start alone waits 30 s for the provider.
    timeout                          = "300s"
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
        for_each = merge(local.server_env, {
          # Polls stop reaching the provider more than once per interval, which also bounds the reads
          # in flight while the provider is slow.
          CHECK_INTERVAL = "10s"
          # 20 concurrent maximum-size submits peak at 1,575 MiB under this limit.
          GOMEMLIMIT              = "1600MiB"
          GRPC_PORT               = "8080"
          POSTGRES_MAX_OPEN_CONNS = "10"
          POSTGRES_MAX_IDLE_CONNS = "10"
        })
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.server_secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = "projects/${local.management_project_id}/secrets/production-genai-${env.value}"
              version = tostring(var.secret_versions[env.value])
            }
          }
        }
      }

      resources {
        limits = { cpu = "1", memory = "2Gi" }
        # Consumers wait on these calls through the API that makes them, so their Sentry events and
        # spans leave in the background, which needs CPU between requests.
        cpu_idle          = false
        startup_cpu_boost = true
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

    # All egress enters the VPC from the egress subnet, which Cloud NAT serves. The egress allowlist
    # lets only the provider's API and Sentry out.
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
      condition     = (self.scaling[0].max_instance_count + 1) * tonumber(self.template[0].containers[0].resources[0].limits.cpu) * 1000 <= local.foundation.cloud_run_cpu_quotas["private"]
      error_message = "The maximum instances, plus one during a rollout, must fit the private Cloud Run CPU quota. Raise the quota in foundation first."
    }
  }
}

# Foundation's Cloud Scheduler job calls the sweep every minute, GenAI's default SWEEP_INTERVAL.
# Each call checks the generations nobody polled.
resource "google_cloud_run_v2_service" "sweep" {
  name                 = "agora-genai-sweep"
  location             = local.region
  ingress              = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  invoker_iam_disabled = false
  deletion_protection  = true
  labels               = { environment = "production", component = "genai", role = "sweep" }

  scaling {
    min_instance_count = 0
    max_instance_count = 1
  }

  template {
    service_account = module.runtime.workloads["sweep"].service_account
    # Above the sweep's own 2 m request and 2 m 15 s write timeouts, so its answer arrives.
    timeout = "300s"
    # Overlapping calls share the instance's checks, so a late call can overlap the next one.
    max_instance_request_concurrency = 2
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"

    containers {
      name  = "sweep"
      image = local.image.sweep

      ports {
        container_port = 8080
      }

      dynamic "env" {
        for_each = merge(local.server_env, {
          # A sweep starts pending generations, which reads their payloads: 4 checks fit 1 GiB.
          GOMEMLIMIT              = "800MiB"
          POSTGRES_MAX_OPEN_CONNS = "4"
          POSTGRES_MAX_IDLE_CONNS = "4"
          REST_PORT               = "8080"
        })
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = local.server_secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = "projects/${local.management_project_id}/secrets/production-genai-${env.value}"
              version = tostring(var.secret_versions[env.value])
            }
          }
        }
      }

      resources {
        limits = { cpu = "1", memory = "1Gi" }
        # No consumer waits on the sweep, so it sends its Sentry events and spans before each answer,
        # and CPU between the scheduler's calls would only keep it billed.
        cpu_idle          = true
        startup_cpu_boost = true
      }

      startup_probe {
        timeout_seconds   = 1
        period_seconds    = 3
        failure_threshold = 80
        http_get {
          path = "/ping"
          port = 8080
        }
      }
    }

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

  depends_on = [google_cloud_run_v2_job.migrations]

  lifecycle {
    prevent_destroy = true

    postcondition {
      condition     = (self.scaling[0].max_instance_count + 1) * tonumber(self.template[0].containers[0].resources[0].limits.cpu) * 1000 <= local.foundation.cloud_run_cpu_quotas["private"]
      error_message = "The maximum instances, plus one during a rollout, must fit the private Cloud Run CPU quota. Raise the quota in foundation first."
    }
  }
}

# The smoke check runs as its own identity, which may only invoke the gRPC service.
module "smoke" {
  source = "../../../modules/smoke-check"

  service = "genai"
  region  = local.region
  target = {
    name       = google_cloud_run_v2_service.grpc.name
    uri        = google_cloud_run_v2_service.grpc.uri
    status_rpc = "anovel.genai.v0.StatusService/Status"
  }
  image           = local.image.grpc
  service_account = module.runtime.workloads["smoke"].service_account
  network         = local.network
  downtime_start  = try(local.downtime_env.DOWNTIME_START, "")
}
