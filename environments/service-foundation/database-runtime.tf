variable "database_runtime" {
  description = "Database lifecycle owned by foundation maintenance. Reuses the service's repository image, loader and CA; bring-up, WAL archiving and backup alerts are separate opt-ins."
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
    condition     = var.database_runtime == null ? true : try(var.pgbackrest_repository.runtime != null, false)
    error_message = "The database lifecycle requires the service's prepared repository runtime."
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
  database_runtime = var.database_runtime == null ? {} : {
    for key, runtime in local.repository_runtime : key => merge(runtime, var.database_runtime)
  }
  database_cloud_config = { for key, runtime in module.database_runtime : key => runtime.cloud_config }
}

module "database_runtime" {
  source   = "../../modules/database-runtime"
  for_each = local.database_runtime

  project_id        = var.project_id
  service           = var.service
  region            = var.region
  management_number = trimprefix(trimsuffix(var.state_bucket, "-tofu-state"), "${var.management_project_id}-")
  identity_version  = each.value.identity_version
  wal_archiving     = each.value.wal_archiving
  repository = merge(each.value, {
    name = local.repository_name
    ip   = google_compute_instance.repository[each.key].network_interface[0].network_ip
  })
}

resource "google_artifact_registry_repository_iam_member" "database_tooling" {
  for_each = local.database_runtime

  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.images["agora-tooling"].repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.database[each.key].email}"
}
