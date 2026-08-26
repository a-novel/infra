resource "google_cloud_run_v2_job" "postgres_backup" {
  for_each = var.recovery_mode ? {} : local.enabled_database_contracts

  project  = var.workload_project_id
  location = var.region
  name     = "agora-postgres-backup-${each.value.object_key}"

  # DISK-backed emptyDir volumes are a Cloud Run Preview feature. The 10 GiB
  # minimum stays within the default per-instance quota and avoids a quota request.
  launch_stage = "BETA"

  deletion_protection = false
  labels              = merge(local.labels, { component = each.value.object_key, role = "backup" })
  tags = {
    (var.cloud_run_invocation_tags.key) = var.cloud_run_invocation_tags.values.scheduled
  }

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = var.runtime_service_accounts.backup
      max_retries           = 1
      timeout               = "1800s"
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

      containers {
        name    = "backup"
        image   = each.value.image
        command = ["/bin/bash", "-c"]
        args    = [file("${path.module}/scripts/postgres-backup.sh")]

        dynamic "env" {
          for_each = {
            BACKUP_ROLE         = each.value.backup_role
            DATABASE_HOST       = var.database_private_ip
            DATABASE_IMAGE      = each.value.image
            DATABASE_KEY        = each.value.object_key
            DATABASE_NAME       = each.value.database_name
            DATABASE_OWNER      = each.value.owner
            DATABASE_PORT       = tostring(each.value.port)
            EXPECTED_EXTENSIONS = each.value.extensions
            SOURCE_PROJECT_ID   = var.workload_project_id
          }

          content {
            name  = env.key
            value = env.value
          }
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }

        volume_mounts {
          name       = "workspace"
          mount_path = "/workspace"
        }

        volume_mounts {
          name       = "database-password"
          mount_path = "/secrets"
        }
      }

      # The sidecar is intentionally a stock curl image. The backup identity
      # can only create objects, so GCS FUSE's broader writer role is avoided.
      containers {
        name    = "upload"
        image   = var.backup_uploader_image
        command = ["/bin/su"]
        args    = ["-s", "/bin/sh", "nobody", "-c", file("${path.module}/scripts/postgres-backup-upload.sh")]

        env {
          name  = "BACKUP_BUCKET"
          value = var.backup_bucket_name
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        volume_mounts {
          name       = "workspace"
          mount_path = "/workspace"
        }
      }

      volumes {
        name = "workspace"

        empty_dir {
          medium     = "DISK"
          size_limit = "10Gi"
        }
      }

      volumes {
        name = "database-password"

        secret {
          secret = "projects/${var.management_project_id}/secrets/${each.value.secret_id}"

          items {
            version = tostring(each.value.backup_password_version)
            path    = "password"
            mode    = 256
          }
        }
      }

      vpc_access {
        egress = "ALL_TRAFFIC"

        network_interfaces {
          network    = var.network_id
          subnetwork = var.subnet_id
          tags       = ["agora-backup"]
        }
      }
    }
  }

  # Google can normalize the launch stage after feature enrollment. Keep that
  # provider-side normalization from creating release-plan noise.
  lifecycle {
    ignore_changes = [launch_stage]
  }
}

resource "google_cloud_run_v2_job" "postgres_restore" {
  for_each = var.recovery_mode ? {} : local.enabled_database_contracts

  project  = var.workload_project_id
  location = var.region
  name     = "agora-postgres-restore-${each.value.object_key}"

  # Restore uses the same bounded Preview disk contract as backup. Ten GiB is
  # the supported minimum and requires no project quota increase.
  launch_stage = "BETA"

  deletion_protection = false
  labels              = merge(local.labels, { component = each.value.object_key, role = "restore" })
  tags = {
    (var.cloud_run_invocation_tags.key) = var.cloud_run_invocation_tags.values.scheduled
  }

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = var.runtime_service_accounts.restore
      max_retries           = 0
      timeout               = "3600s"
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

      containers {
        name    = "restore"
        image   = each.value.image
        command = ["/bin/bash", "-c"]
        args    = [file("${path.module}/scripts/postgres-restore.sh")]

        dynamic "env" {
          for_each = {
            BACKUP_ROLE         = each.value.backup_role
            DATABASE_HOST       = var.database_private_ip
            DATABASE_IMAGE      = each.value.image
            DATABASE_KEY        = each.value.object_key
            DATABASE_NAME       = each.value.database_name
            DATABASE_OWNER      = each.value.owner
            DATABASE_PORT       = tostring(each.value.port)
            EXPECTED_EXTENSIONS = each.value.extensions
            SOURCE_PROJECT_ID   = var.workload_project_id
          }

          content {
            name  = env.key
            value = env.value
          }
        }

        resources {
          limits = {
            cpu    = "2"
            memory = "4Gi"
          }
        }

        volume_mounts {
          name       = "backups"
          mount_path = "/backups"
        }

        volume_mounts {
          name       = "workspace"
          mount_path = "/workspace"
        }
      }

      volumes {
        name = "backups"

        gcs {
          bucket    = var.backup_bucket_name
          read_only = true
        }
      }

      volumes {
        name = "workspace"

        empty_dir {
          medium     = "DISK"
          size_limit = "10Gi"
        }
      }

      # Restore has access to the backup payload, so all of its traffic enters
      # the deny-by-default VPC. Its tag has no route to production PostgreSQL.
      vpc_access {
        egress = "ALL_TRAFFIC"

        network_interfaces {
          network    = var.network_id
          subnetwork = var.subnet_id
          tags       = ["agora-restore"]
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [launch_stage]
  }
}

# These jobs exist only in a separately stated disposable recovery project.
# They first run the normal clean-restore drill, then restore the exact selected
# attempt into an empty private target. Production state cannot create them.
resource "google_cloud_run_v2_job" "postgres_recover" {
  for_each = var.recovery_mode ? local.enabled_database_contracts : {}

  project  = var.workload_project_id
  location = var.region
  # Reuse is safe only when the immutable archive, validation image, and target
  # owner credential are identical. A changed contract gets a new job and then
  # fails on the non-empty target instead of reusing unrelated success.
  name = "agora-postgres-recover-${each.value.object_key}-${substr(sha256(jsonencode({
    attempt          = var.recovery_backup_attempts[each.key]
    database_image   = var.recovery_database_images[each.key]
    password_version = var.recovery_database_password_versions[each.key]
  })), 0, 8)}"

  launch_stage        = "BETA"
  deletion_protection = false
  labels              = merge(local.labels, { component = each.value.object_key, role = "recovery" })
  tags = {
    (var.cloud_run_invocation_tags.key) = var.cloud_run_invocation_tags.values.recovery
  }

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = var.runtime_service_accounts.restore
      max_retries           = 0
      timeout               = "3600s"
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

      containers {
        name    = "recover"
        image   = each.value.image
        command = ["/bin/bash", "-c"]
        args = [join("\n", [
          file("${path.module}/scripts/postgres-restore.sh"),
          file("${path.module}/scripts/postgres-recover.sh"),
        ])]

        dynamic "env" {
          for_each = {
            BACKUP_ROLE          = each.value.backup_role
            DATABASE_HOST        = var.database_private_ip
            DATABASE_IMAGE       = var.recovery_database_images[each.key]
            DATABASE_KEY         = each.value.object_key
            DATABASE_NAME        = each.value.database_name
            DATABASE_OWNER       = each.value.owner
            DATABASE_PORT        = tostring(each.value.port)
            EXPECTED_EXTENSIONS  = each.value.extensions
            RECOVERY_ATTEMPT     = var.recovery_backup_attempts[each.key]
            RECOVERY_PROJECT_ID  = var.workload_project_id
            RECOVERY_TARGET      = "true"
            SOURCE_DATABASE_HOST = var.recovery_source_database_ip
            SOURCE_PROJECT_ID    = var.recovery_source_project_id
          }

          content {
            name  = env.key
            value = env.value
          }
        }

        resources {
          limits = {
            cpu    = "2"
            memory = "4Gi"
          }
        }

        volume_mounts {
          name       = "backups"
          mount_path = "/backups"
        }

        volume_mounts {
          name       = "workspace"
          mount_path = "/workspace"
        }

        volume_mounts {
          name       = "database-password"
          mount_path = "/secrets"
        }
      }

      volumes {
        name = "backups"

        gcs {
          bucket    = var.backup_bucket_name
          read_only = true
        }
      }

      volumes {
        name = "workspace"

        empty_dir {
          medium     = "DISK"
          size_limit = "10Gi"
        }
      }

      volumes {
        name = "database-password"

        secret {
          secret = "projects/${var.management_project_id}/secrets/${each.value.owner_secret_id}"

          items {
            version = tostring(var.recovery_database_password_versions[each.key])
            path    = "password"
            mode    = 256
          }
        }
      }

      vpc_access {
        egress = "ALL_TRAFFIC"

        network_interfaces {
          network    = var.network_id
          subnetwork = var.subnet_id
          tags       = ["agora-restore"]
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [launch_stage]
  }
}

resource "google_cloud_run_v2_job" "postgres_backup_monitor" {
  count = length(local.enabled_database_contracts) == 0 || var.recovery_mode ? 0 : 1

  project  = var.workload_project_id
  location = var.region
  name     = "agora-postgres-backup-monitor"

  deletion_protection = false
  labels              = merge(local.labels, { component = "postgres", role = "backup-monitor" })
  tags = {
    (var.cloud_run_invocation_tags.key) = var.cloud_run_invocation_tags.values.scheduled
  }

  template {
    task_count  = 1
    parallelism = 1

    template {
      service_account       = var.runtime_service_accounts.restore
      max_retries           = 1
      timeout               = "300s"
      execution_environment = "EXECUTION_ENVIRONMENT_GEN2"

      containers {
        name    = "monitor"
        image   = var.backup_uploader_image
        command = ["/bin/sh", "-c"]
        args    = [file("${path.module}/scripts/postgres-backup-monitor.sh")]

        env {
          name  = "DATABASE_KEYS"
          value = join(" ", sort([for contract in values(local.enabled_database_contracts) : contract.object_key]))
        }

        env {
          name  = "RPO_SECONDS"
          value = "21600"
        }

        # At the current EU cadence, 250 GiB retained keeps storage, write
        # replication, and one monthly restore below the USD 20 design gate.
        env {
          name  = "STORAGE_ALERT_BYTES"
          value = "268435456000"
        }

        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }

        volume_mounts {
          name       = "backups"
          mount_path = "/backups"
        }
      }

      volumes {
        name = "backups"

        gcs {
          bucket    = var.backup_bucket_name
          read_only = true
        }
      }

      vpc_access {
        egress = "ALL_TRAFFIC"

        network_interfaces {
          network    = var.network_id
          subnetwork = var.subnet_id
          tags       = ["agora-restore"]
        }
      }
    }
  }
}

resource "google_cloud_scheduler_job" "postgres_backup" {
  for_each = var.recovery_mode ? {} : local.enabled_database_contracts

  project   = var.workload_project_id
  region    = var.region
  name      = "agora-postgres-backup-${each.value.object_key}"
  schedule  = each.value.backup_cron
  time_zone = "Etc/UTC"
  paused    = try(var.application_release.rollout.phase, null) != "active"

  attempt_deadline = "180s"

  retry_config {
    retry_count          = 1
    min_backoff_duration = "30s"
    max_backoff_duration = "60s"
    max_doublings        = 0
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.workload_project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.postgres_backup[each.key].name}:run"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")

    oauth_token {
      service_account_email = var.runtime_service_accounts.scheduler_invoker
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
}

resource "google_cloud_scheduler_job" "postgres_restore" {
  for_each = var.recovery_mode ? {} : local.enabled_database_contracts

  project   = var.workload_project_id
  region    = var.region
  name      = "agora-postgres-restore-${each.value.object_key}"
  schedule  = each.value.restore_cron
  time_zone = "Etc/UTC"
  paused    = try(var.application_release.rollout.phase, null) != "active"

  attempt_deadline = "180s"

  retry_config {
    retry_count          = 1
    min_backoff_duration = "30s"
    max_backoff_duration = "60s"
    max_doublings        = 0
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.workload_project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.postgres_restore[each.key].name}:run"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")

    oauth_token {
      service_account_email = var.runtime_service_accounts.scheduler_invoker
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
}

resource "google_cloud_scheduler_job" "postgres_backup_monitor" {
  count = length(local.enabled_database_contracts) == 0 || var.recovery_mode ? 0 : 1

  project   = var.workload_project_id
  region    = var.region
  name      = "agora-postgres-backup-monitor"
  schedule  = "5 * * * *"
  time_zone = "Etc/UTC"
  paused    = try(var.application_release.rollout.phase, null) != "active"

  attempt_deadline = "180s"

  retry_config {
    retry_count          = 1
    min_backoff_duration = "30s"
    max_backoff_duration = "60s"
    max_doublings        = 0
  }

  http_target {
    http_method = "POST"
    uri         = "https://run.googleapis.com/v2/projects/${var.workload_project_id}/locations/${var.region}/jobs/${google_cloud_run_v2_job.postgres_backup_monitor[0].name}:run"
    headers     = { "Content-Type" = "application/json" }
    body        = base64encode("{}")

    oauth_token {
      service_account_email = var.runtime_service_accounts.scheduler_invoker
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }
}
