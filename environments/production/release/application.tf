locals {
  application_images = var.application_release == null ? {} : {
    "service-authentication/jobs/init"       = var.application_release.authentication.images.init
    "service-authentication/jobs/migrations" = var.application_release.authentication.images.migrations
    "service-authentication/rest"            = var.application_release.authentication.images.rest
    "service-json-keys/grpc"                 = var.application_release.json_keys.images.grpc
    "service-json-keys/jobs/migrations"      = var.application_release.json_keys.images.migrations
    "service-json-keys/jobs/rotatekeys"      = var.application_release.json_keys.images.rotate_keys
  }

  # The database host exposes no TLS listener. Private VPC routing, caller
  # tags, container egress controls, and database credentials form this boundary.
  application_database_environment = {
    for key, contract in local.database_contracts : key => {
      POSTGRES_HOST        = var.database_private_ip
      POSTGRES_PORT        = tostring(contract.port)
      POSTGRES_USER        = contract.owner
      POSTGRES_DATABASE    = contract.database_name
      POSTGRES_TLS_ENABLED = "false"
    }
  }

  declared_application_jobs = var.application_release == null ? {} : {
    authentication_migrations = {
      component        = "authentication"
      environment      = local.application_database_environment.authentication
      image            = var.application_release.authentication.images.migrations
      invocation_class = "release"
      max_retries      = 0
      name             = "agora-authentication-migrations"
      network_tag      = "agora-authentication"
      role             = "migrations"
      runtime_identity = var.runtime_service_accounts.authentication
      secrets = {
        POSTGRES_PASSWORD = {
          secret  = "production-authentication-postgres-password"
          version = var.application_release.authentication.secrets.postgres_password_version
        }
      }
      timeout = "600s"
    }
    json_keys_migrations = {
      component        = "json-keys"
      environment      = local.application_database_environment.json_keys
      image            = var.application_release.json_keys.images.migrations
      invocation_class = "release"
      max_retries      = 0
      name             = "agora-json-keys-migrations"
      network_tag      = "agora-json-keys"
      role             = "migrations"
      runtime_identity = var.runtime_service_accounts.json_keys
      secrets = {
        POSTGRES_PASSWORD = {
          secret  = "production-json-keys-postgres-password"
          version = var.application_release.json_keys.secrets.postgres_password_version
        }
      }
      timeout = "600s"
    }
    json_keys_rotate = {
      component        = "json-keys"
      environment      = local.application_database_environment.json_keys
      image            = var.application_release.json_keys.images.rotate_keys
      invocation_class = "scheduled"
      max_retries      = 1
      name             = "agora-json-keys-rotatekeys"
      network_tag      = "agora-json-keys"
      role             = "rotatekeys"
      runtime_identity = var.runtime_service_accounts.json_keys
      secrets = {
        APP_MASTER_KEY = {
          secret  = "production-json-keys-app-master-key"
          version = var.application_release.json_keys.secrets.app_master_key_version
        }
        POSTGRES_PASSWORD = {
          secret  = "production-json-keys-postgres-password"
          version = var.application_release.json_keys.secrets.postgres_password_version
        }
      }
      timeout = "300s"
    }
  }

  # Recovery restores an initialized database from an exact receipt. Recreating
  # production mutation jobs would widen authority without a caller.
  application_jobs = var.recovery_mode ? {} : local.declared_application_jobs
}

check "application_images_are_promoted" {
  assert {
    condition = alltrue([
      for path, image in local.application_images :
      can(regex(
        "^${var.region}-docker\\.pkg\\.dev/${var.workload_project_id}/agora-production/${path}@sha256:[a-f0-9]{64}$",
        image,
      ))
    ])
    error_message = "Application services and jobs must use their exact promoted Artifact Registry digest."
  }
}

check "application_requires_database_release" {
  assert {
    condition = (
      var.application_release == null ||
      toset(keys(var.database_releases)) == toset(["authentication", "json_keys"])
    )
    error_message = "Application services and jobs require both database release contracts."
  }
}

resource "google_cloud_run_v2_job" "application" {
  for_each = local.application_jobs

  project  = var.workload_project_id
  location = var.region
  name     = each.value.name

  deletion_protection = false
  labels = merge(local.labels, {
    component = each.value.component
    role      = each.value.role
  })

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = each.value.runtime_identity
      max_retries           = each.value.max_retries
      timeout               = each.value.timeout
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

      containers {
        name  = each.value.role
        image = each.value.image

        dynamic "env" {
          for_each = each.value.environment

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
                secret  = "projects/${var.management_project_id}/secrets/${env.value.secret}"
                version = tostring(env.value.version)
              }
            }
          }
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }

      vpc_access {
        egress = "ALL_TRAFFIC"

        network_interfaces {
          network    = var.network_id
          subnetwork = var.subnet_id
          tags       = [each.value.network_tag]
        }
      }
    }
  }
}

# The shortest embedded key interval is 24 hours. An hourly idempotent check
# keeps rotation lag below one hour without a resident worker.
resource "google_cloud_scheduler_job" "json_keys_rotation" {
  depends_on = [google_tags_location_tag_binding.application]

  count = var.application_release == null || var.recovery_mode ? 0 : 1

  project   = var.workload_project_id
  region    = var.region
  name      = "agora-json-keys-rotation"
  schedule  = "10 * * * *"
  time_zone = "Etc/UTC"
  # Candidate reconciliation pauses periodic writes until migrations, smoke
  # checks, and both traffic shifts complete. Active/rollback inputs resume it.
  paused = var.application_release.rollout.phase != "active"

  attempt_deadline = "180s"

  retry_config {
    retry_count          = 1
    min_backoff_duration = "30s"
    max_backoff_duration = "60s"
    max_doublings        = 5
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.workload_project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.application["json_keys_rotate"].name}:run"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")

    oauth_token {
      service_account_email = var.runtime_service_accounts.scheduler_invoker
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
}

resource "google_cloud_run_v2_service" "json_keys" {
  count = var.application_release == null ? 0 : 1

  project  = var.workload_project_id
  location = var.region
  name     = "agora-json-keys-grpc"

  ingress              = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  invoker_iam_disabled = false
  deletion_protection  = false
  labels               = merge(local.labels, { component = "json-keys", role = "grpc" })

  scaling {
    min_instance_count = 0
    max_instance_count = 3
  }

  template {
    revision                         = var.application_release.json_keys.revision
    service_account                  = var.runtime_service_accounts.json_keys
    timeout                          = "60s"
    max_instance_request_concurrency = 20
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"

    containers {
      name  = "grpc"
      image = var.application_release.json_keys.images.grpc

      ports {
        name           = "h2c"
        container_port = 8080
      }

      env {
        name  = "GCLOUD_PROJECT_ID"
        value = var.workload_project_id
      }

      env {
        name  = "GRPC_PORT"
        value = "8080"
      }

      env {
        name  = "POSTGRES_MAX_IDLE_CONNS"
        value = "10"
      }

      env {
        name  = "POSTGRES_MAX_OPEN_CONNS"
        value = "20"
      }

      dynamic "env" {
        for_each = local.application_database_environment.json_keys

        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name = "APP_MASTER_KEY"

        value_source {
          secret_key_ref {
            secret  = "projects/${var.management_project_id}/secrets/production-json-keys-app-master-key"
            version = tostring(var.application_release.json_keys.secrets.app_master_key_version)
          }
        }
      }

      env {
        name = "POSTGRES_PASSWORD"

        value_source {
          secret_key_ref {
            secret  = "projects/${var.management_project_id}/secrets/production-json-keys-postgres-password"
            version = tostring(var.application_release.json_keys.secrets.postgres_password_version)
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = false
      }

      # The image's standard gRPC health service alternates SERVING and
      # NOT_SERVING for local echo testing. A TCP startup probe verifies that
      # the real h2c listener is ready without introducing random restarts.
      startup_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 1
        period_seconds        = 3
        failure_threshold     = 80

        tcp_socket {
          port = 8080
        }
      }
    }

    vpc_access {
      egress = "ALL_TRAFFIC"

      network_interfaces {
        network    = var.network_id
        subnetwork = var.subnet_id
        tags       = ["agora-json-keys"]
      }
    }
  }

  dynamic "traffic" {
    for_each = var.application_release.rollout.phase == "candidate" && var.application_release.json_keys.active_revision != null ? [1] : []

    content {
      type     = "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION"
      revision = var.application_release.json_keys.active_revision
      percent  = 100
    }
  }

  dynamic "traffic" {
    for_each = var.application_release.rollout.phase == "candidate" ? [1] : []

    content {
      type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
      percent = var.application_release.json_keys.active_revision == null ? 100 : 0
      tag     = var.application_release.rollout.candidate_tag
    }
  }

  dynamic "traffic" {
    for_each = var.application_release.rollout.phase == "active" ? [1] : []

    content {
      type     = var.recovery_mode ? "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST" : "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION"
      revision = var.recovery_mode ? null : var.application_release.json_keys.active_revision
      percent  = 100
    }
  }
}

resource "google_cloud_run_v2_service" "authentication" {
  count = var.application_release == null ? 0 : 1

  project  = var.workload_project_id
  location = var.region
  name     = "agora-authentication-rest"

  ingress = var.recovery_mode ? "INGRESS_TRAFFIC_INTERNAL_ONLY" : "INGRESS_TRAFFIC_ALL"
  # Google recommends disabling the Invoker IAM check for a public service.
  # Authentication keeps authorization in the application without an allUsers
  # IAM binding that conflicts with domain-restricted sharing policies.
  invoker_iam_disabled = var.recovery_mode ? false : true
  deletion_protection  = false
  labels               = merge(local.labels, { component = "authentication", role = "rest" })

  scaling {
    min_instance_count = 0
    max_instance_count = 3
  }

  template {
    revision                         = var.application_release.authentication.revision
    service_account                  = var.runtime_service_accounts.authentication
    timeout                          = "60s"
    max_instance_request_concurrency = 20
    execution_environment            = "EXECUTION_ENVIRONMENT_GEN2"

    containers {
      name  = "rest"
      image = var.application_release.authentication.images.rest

      ports {
        name           = "http1"
        container_port = 8080
      }

      env {
        name  = "GCLOUD_PROJECT_ID"
        value = var.workload_project_id
      }

      env {
        name  = "POSTGRES_MAX_IDLE_CONNS"
        value = "10"
      }

      env {
        name  = "POSTGRES_MAX_OPEN_CONNS"
        value = "20"
      }

      dynamic "env" {
        for_each = local.application_database_environment.authentication

        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name  = "REST_PORT"
        value = "8080"
      }

      # Cloud Run sends SIGTERM ten seconds before termination. The shared
      # nine-second budget lets the HTTP server stop and detached mail sends
      # drain before the platform's fixed deadline.
      env {
        name  = "REST_TIMEOUT_SHUTDOWN"
        value = "9s"
      }

      env {
        name  = "SERVICE_JSON_KEYS_HOST"
        value = trimprefix(google_cloud_run_v2_service.json_keys[0].uri, "https://")
      }

      env {
        name  = "SERVICE_JSON_KEYS_PORT"
        value = "443"
      }

      env {
        name  = "SMTP_ADDR"
        value = var.application_release.authentication.smtp.address
      }

      env {
        name  = "SMTP_MAX_CONCURRENT"
        value = "8"
      }

      env {
        name  = "SMTP_SENDER_DOMAIN"
        value = var.application_release.authentication.smtp.sender_domain
      }

      env {
        name  = "SMTP_SENDER_EMAIL"
        value = var.application_release.authentication.smtp.sender_email
      }

      env {
        name  = "SMTP_SENDER_NAME"
        value = var.application_release.authentication.smtp.sender_name
      }

      env {
        name  = "SMTP_TIMEOUT"
        value = "5s"
      }

      # SMTP login and sender identity are separate contracts. Some providers
      # use a project key or tenant login that is not a valid From address.
      env {
        name  = "SMTP_USERNAME"
        value = var.application_release.authentication.smtp.username
      }

      env {
        name = "POSTGRES_PASSWORD"

        value_source {
          secret_key_ref {
            secret  = "projects/${var.management_project_id}/secrets/production-authentication-postgres-password"
            version = tostring(var.application_release.authentication.secrets.postgres_password_version)
          }
        }
      }

      env {
        name = "SMTP_SENDER_PASSWORD"

        value_source {
          secret_key_ref {
            secret  = "projects/${var.management_project_id}/secrets/production-authentication-smtp-sender-password"
            version = tostring(var.application_release.authentication.secrets.smtp_password_version)
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # Registration and recovery emails continue in detached goroutines
        # after their HTTP responses, so this service needs instance-based CPU.
        cpu_idle          = false
        startup_cpu_boost = false
      }

      startup_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 1
        period_seconds        = 3
        failure_threshold     = 80

        http_get {
          path = "/v2/ping"
          port = 8080
        }
      }

      liveness_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 1
        period_seconds        = 30
        failure_threshold     = 3

        http_get {
          path = "/v2/ping"
          port = 8080
        }
      }
    }

    # Private addresses and the private run.app VIP enter the VPC. Public SMTP
    # leaves through Cloud Run's managed egress, so this path needs no NAT.
    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"

      network_interfaces {
        network    = var.network_id
        subnetwork = var.subnet_id
        tags       = ["agora-authentication"]
      }
    }
  }

  dynamic "traffic" {
    for_each = var.application_release.rollout.phase == "candidate" && var.application_release.authentication.active_revision != null ? [1] : []

    content {
      type     = "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION"
      revision = var.application_release.authentication.active_revision
      percent  = 100
    }
  }

  dynamic "traffic" {
    for_each = var.application_release.rollout.phase == "candidate" ? [1] : []

    content {
      type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
      percent = var.application_release.authentication.active_revision == null ? 100 : 0
      tag     = var.application_release.rollout.candidate_tag
    }
  }

  dynamic "traffic" {
    for_each = var.application_release.rollout.phase == "active" ? [1] : []

    content {
      type     = var.recovery_mode ? "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST" : "TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION"
      revision = var.recovery_mode ? null : var.application_release.authentication.active_revision
      percent  = 100
    }
  }
}
