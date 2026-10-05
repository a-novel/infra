variable "database_runtime" {
  description = "JSON Keys lifecycle owned by foundation maintenance. Reuses the repository's image, loader and CA; bring-up, WAL archiving and backup alerts are separate opt-ins."
  type = object({
    revision                = string
    password_version        = string
    backup_password_version = string
    identity_version        = string
    wal_archiving           = optional(bool, false)
    bring_up                = optional(bool, false)
    backup_alerts_enabled   = optional(bool, false)
  })
  default = null

  validation {
    condition     = var.database_runtime == null ? true : var.service == "json-keys" && try(var.pgbackrest_repository.runtime != null, false)
    error_message = "The database lifecycle requires the prepared JSON Keys repository runtime."
  }
  validation {
    condition = var.database_runtime == null ? true : alltrue([
      can(regex("^[0-9a-f]{40}$", var.database_runtime.revision)),
      alltrue([for version in [var.database_runtime.password_version, var.database_runtime.backup_password_version, var.database_runtime.identity_version] :
        can(regex("^[1-9][0-9]{0,19}$", version))
      ]),
    ])
    error_message = "Use a reviewed full revision and positive numeric credential versions, never aliases."
  }
}

locals {
  native_host_bringup = try(var.database_runtime.bring_up, false)
  database_backup_jobs = {
    stanza-create = "stanza-create"
    check         = "check"
    full          = "--type=full --archive-copy --repo1-bundle --no-expire-auto backup"
    diff          = "--type=diff --archive-copy --repo1-bundle --no-expire-auto backup"
    verify        = "--output=text --verbose --log-level-console=error verify"
  }
  database_backup_calendars = {
    full  = "Sun *-*-* 02:00:00 UTC"
    diff  = "Mon..Sat *-*-* 02:00:00 UTC"
    check = "*-*-* *:30:00 UTC"
  }
  database_runtime = var.database_runtime == null ? {} : {
    for key, runtime in local.repository_runtime : key => merge(runtime, var.database_runtime)
  }
  database_cloud_config = { for key, runtime in local.database_runtime : key => "#cloud-config\n${yamlencode({
    write_files = concat([
      {
        path        = "/etc/agora-database/docker/config.json"
        permissions = "0600"
        content     = jsonencode({ credHelpers = { "${var.region}-docker.pkg.dev" = "gcr" } })
      },
      {
        path        = "/etc/agora-database/startup.sh"
        permissions = "0400"
        content     = file("${path.module}/../../assets/database-host/startup.sh")
      },
      {
        path        = "/etc/agora-database/pgbackrest.conf"
        permissions = "0444"
        content     = templatefile("${path.module}/templates/database-pgbackrest.conf.tftpl", { server_name = local.repository_name })
      },
      {
        path        = "/etc/systemd/system/agora-database.service"
        permissions = "0644"
        content = templatefile("${path.module}/templates/database.service.tftpl", merge(runtime, {
          project           = var.project_id
          management_number = trimprefix(trimsuffix(var.state_bucket, "-tofu-state"), "${var.management_project_id}-")
          server_name       = local.repository_name
          server_ip         = google_compute_instance.repository[key].network_interface[0].network_ip
          backup_containers = join(" ", [for name in keys(local.database_backup_jobs) : "agora-backup-${name}"])
        }))
      },
      ], [for name, command in local.database_backup_jobs : {
        path        = "/etc/systemd/system/agora-backup-${name}.service"
        permissions = "0644"
        content = templatefile("${path.module}/templates/database-backup.service.tftpl", {
          name    = name
          command = command
          image   = runtime.server_image
        })
        }], [for name, calendar in local.database_backup_calendars : {
        path        = "/etc/systemd/system/agora-backup-${name}.timer"
        permissions = "0644"
        content     = templatefile("${path.module}/templates/database-backup.timer.tftpl", { name = name, calendar = calendar })
    }])
    # Preparation only registers units; starting timers or services requires separate approval.
    runcmd = [["systemctl", "daemon-reload"]]
  })}" }
}

resource "google_artifact_registry_repository_iam_member" "database_tooling" {
  for_each = local.database_runtime

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.images["agora-tooling"].repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.database[each.key].email}"
}
