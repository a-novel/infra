locals {
  application_images = var.application_release == null ? {} : {
    "service-authentication/jobs/init"       = var.application_release.authentication.images.init
    "service-authentication/jobs/migrations" = var.application_release.authentication.images.migrations
    "service-authentication/rest"            = var.application_release.authentication.images.rest
    "service-json-keys/grpc"                 = var.application_release.json_keys.images.grpc
    "service-json-keys/jobs/migrations"      = var.application_release.json_keys.images.migrations
    "service-json-keys/jobs/rotatekeys"      = var.application_release.json_keys.images.rotate_keys
  }

  application_jobs = var.application_release == null ? {} : {
    authentication_init = {
      component        = "authentication"
      environment      = { SUPER_ADMIN_EMAIL = var.application_release.authentication.super_admin_email }
      image            = var.application_release.authentication.images.init
      max_retries      = 1
      name             = "agora-authentication-init"
      network_tag      = "agora-authentication"
      role             = "init"
      runtime_identity = var.runtime_service_accounts.authentication
      secrets = {
        POSTGRES_DSN = {
          secret  = "production-authentication-postgres-dsn"
          version = var.application_release.authentication.secrets.postgres_dsn_version
        }
        SUPER_ADMIN_PASSWORD = {
          secret  = "production-authentication-super-admin-password"
          version = var.application_release.authentication.secrets.super_admin_password_version
        }
      }
      timeout = "300s"
    }
    authentication_migrations = {
      component        = "authentication"
      environment      = {}
      image            = var.application_release.authentication.images.migrations
      max_retries      = 0
      name             = "agora-authentication-migrations"
      network_tag      = "agora-authentication"
      role             = "migrations"
      runtime_identity = var.runtime_service_accounts.authentication
      secrets = {
        POSTGRES_DSN = {
          secret  = "production-authentication-postgres-dsn"
          version = var.application_release.authentication.secrets.postgres_dsn_version
        }
      }
      timeout = "600s"
    }
    json_keys_migrations = {
      component        = "json-keys"
      environment      = {}
      image            = var.application_release.json_keys.images.migrations
      max_retries      = 0
      name             = "agora-json-keys-migrations"
      network_tag      = "agora-json-keys"
      role             = "migrations"
      runtime_identity = var.runtime_service_accounts.json_keys
      secrets = {
        POSTGRES_DSN = {
          secret  = "production-json-keys-postgres-dsn"
          version = var.application_release.json_keys.secrets.postgres_dsn_version
        }
      }
      timeout = "600s"
    }
    json_keys_rotate = {
      component        = "json-keys"
      environment      = {}
      image            = var.application_release.json_keys.images.rotate_keys
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
        POSTGRES_DSN = {
          secret  = "production-json-keys-postgres-dsn"
          version = var.application_release.json_keys.secrets.postgres_dsn_version
        }
      }
      timeout = "300s"
    }
  }

  json_keys_invokers = var.application_release == null ? {} : {
    authentication = "serviceAccount:${var.runtime_service_accounts.authentication}"
    recovery       = "serviceAccount:infra-recovery@${var.management_project_id}.iam.gserviceaccount.com"
    release        = "serviceAccount:infra-release@${var.management_project_id}.iam.gserviceaccount.com"
  }
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
        name = "POSTGRES_DSN"

        value_source {
          secret_key_ref {
            secret  = "projects/${var.management_project_id}/secrets/production-json-keys-postgres-dsn"
            version = tostring(var.application_release.json_keys.secrets.postgres_dsn_version)
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
        failure_threshold     = 20

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

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }
}

resource "google_cloud_run_v2_service_iam_member" "json_keys_invoker" {
  for_each = local.json_keys_invokers

  project  = var.workload_project_id
  location = var.region
  name     = google_cloud_run_v2_service.json_keys[0].name
  role     = "roles/run.invoker"
  member   = each.value
}

resource "google_cloud_run_v2_service" "authentication" {
  count = var.application_release == null ? 0 : 1

  project  = var.workload_project_id
  location = var.region
  name     = "agora-authentication-rest"

  ingress = "INGRESS_TRAFFIC_ALL"
  # Google recommends disabling the Invoker IAM check for a public service.
  # Authentication keeps authorization in the application without an allUsers
  # IAM binding that conflicts with domain-restricted sharing policies.
  invoker_iam_disabled = true
  deletion_protection  = false
  labels               = merge(local.labels, { component = "authentication", role = "rest" })

  scaling {
    min_instance_count = 0
    max_instance_count = 3
  }

  template {
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

      env {
        name = "POSTGRES_DSN"

        value_source {
          secret_key_ref {
            secret  = "projects/${var.management_project_id}/secrets/production-authentication-postgres-dsn"
            version = tostring(var.application_release.authentication.secrets.postgres_dsn_version)
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
        failure_threshold     = 20

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

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [google_cloud_run_v2_service_iam_member.json_keys_invoker]
}
