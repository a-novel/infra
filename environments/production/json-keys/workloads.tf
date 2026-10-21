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
    POSTGRES_USER        = "agora_json_keys_app"
    POSTGRES_DATABASE    = "agora_json_keys"
    POSTGRES_TLS_ENABLED = "false"
    # Signing reads keys from a cache, so a few connections serve every instance. Two instances and
    # a rollout's third, plus the jobs, stay well under the database's connection ceiling.
    POSTGRES_MAX_OPEN_CONNS = "5"
    POSTGRES_MAX_IDLE_CONNS = "2"
  }
  secret_env = {
    POSTGRES_PASSWORD = "app-password"
    APP_MASTER_KEY    = "app-master-key"
  }
  jobs = {
    migrations = { timeout = "600s", retries = 0, secrets = { POSTGRES_PASSWORD = "app-password" } }
    rotatekeys = { timeout = "300s", retries = 1, secrets = local.secret_env }
  }
}

# Cloud Run names an execution after its job and token, and refuses a name it has used before. The
# token comes from this terraform_data's ID, which is new each time a trigger replaces it, even on a
# revert to an older image. Hashing fits the token into the 63-character execution name. A new
# identity or database user is a trigger too, so the migration proves its grants and login at once.
resource "terraform_data" "migrations" {
  triggers_replace = [local.image.migrations, module.runtime.workloads["migrations"].service_account, local.database_env.POSTGRES_USER]
}

resource "google_cloud_run_v2_job" "application" {
  for_each = local.jobs

  name                = "agora-json-keys-${each.key}"
  location            = local.region
  deletion_protection = true
  labels              = { environment = "production", component = "json-keys", role = each.key }

  # Apply runs the migration once per image change and fails until it succeeds.
  run_execution_token = each.key == "migrations" ? substr(sha256(terraform_data.migrations.id), 0, 24) : null

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = module.runtime.workloads[each.key].service_account
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
    max_instance_count = 2
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
          GCLOUD_PROJECT_ID = local.project_id
          # The Go runtime does not read the container's memory limit.
          GOMEMLIMIT = "400MiB"
          GRPC_PORT  = "8080"
          OTEL       = "true"
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

    postcondition {
      condition     = (self.scaling[0].max_instance_count + 1) * tonumber(self.template[0].containers[0].resources[0].limits.cpu) * 1000 <= local.foundation.cloud_run_cpu_quotas["private"]
      error_message = "The maximum instances, plus one during a rollout, must fit the private Cloud Run CPU quota. Raise the quota in foundation first."
    }
  }
}

# The smoke check runs as its own identity, which may only invoke the gRPC service.
module "smoke" {
  source = "../../../modules/smoke-check"

  service = "json-keys"
  region  = local.region
  target = {
    name       = google_cloud_run_v2_service.grpc.name
    uri        = google_cloud_run_v2_service.grpc.uri
    status_rpc = "anovel.jsonkeys.v2.StatusService/Status"
  }
  image           = local.image.grpc
  service_account = module.runtime.workloads["smoke"].service_account
  network         = local.network
  downtime_start  = try(local.downtime_env.DOWNTIME_START, "")
}
