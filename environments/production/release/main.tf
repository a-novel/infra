provider "google" {
  project = var.workload_project_id
  region  = var.region

  default_labels = local.labels
}

locals {
  root_name = "release"

  labels = {
    application = "agora"
    environment = "production"
    managed-by  = "opentofu"
    plane       = "release"
  }

  database_contracts = {
    authentication = {
      backup_cron     = "45 */4 * * *"
      backup_role     = "agora_authentication_backup"
      database_name   = "agora_authentication"
      extensions      = "plpgsql,uuid-ossp"
      object_key      = "authentication"
      owner           = "agora_authentication"
      owner_secret_id = "production-authentication-postgres-password"
      port            = 5433
      restore_cron    = "45 3 1 * *"
      secret_id       = "production-authentication-postgres-backup-password"
    }
    json_keys = {
      backup_cron     = "15 */4 * * *"
      backup_role     = "agora_json_keys_backup"
      database_name   = "agora_json_keys"
      extensions      = "plpgsql,uuid-ossp"
      object_key      = "json-keys"
      owner           = "agora_json_keys"
      owner_secret_id = "production-json-keys-postgres-password"
      port            = 5432
      restore_cron    = "15 3 1 * *"
      secret_id       = "production-json-keys-postgres-backup-password"
    }
  }

  enabled_database_contracts = {
    for key, release in var.database_releases : key => merge(
      local.database_contracts[key],
      release,
    )
  }
}

check "recovery_is_disposable" {
  assert {
    condition = var.recovery_mode ? (
      var.recovery_source_project_id != null &&
      var.recovery_source_database_ip != null &&
      var.recovery_source_project_id != var.workload_project_id &&
      length(var.database_releases) == 2
      ) : (
      var.recovery_source_project_id == null &&
      var.recovery_source_database_ip == null &&
      length(var.recovery_database_images) == 0 &&
      length(var.recovery_backup_attempts) == 0 &&
      length(var.recovery_database_password_versions) == 0
    )
    error_message = "Recovery mode requires a different source project and both database releases; production accepts no recovery-only inputs."
  }
}

check "recovery_database_images_match_source" {
  assert {
    condition = !var.recovery_mode || alltrue([
      for key, image in var.recovery_database_images : can(regex(
        "^[a-z]+-[a-z]+[0-9]+-docker\\.pkg\\.dev/${var.recovery_source_project_id}/agora-production/service-${replace(key, "_", "-")}/database@sha256:[a-f0-9]{64}$",
        image,
      ))
    ])
    error_message = "Recovery source database images must be the selected receipt's original promoted digests."
  }
}

check "database_images_are_promoted" {
  assert {
    condition = alltrue([
      for key, release in var.database_releases :
      can(regex(
        "^${var.region}-docker\\.pkg\\.dev/${var.workload_project_id}/agora-production/service-${replace(key, "_", "-")}/database@sha256:[a-f0-9]{64}$",
        release.image,
      ))
    ])
    error_message = "Database recovery jobs must use the exact promoted Artifact Registry digest for their service."
  }
}
