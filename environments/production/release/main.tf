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
      backup_cron   = "45 */4 * * *"
      backup_role   = "agora_authentication_backup"
      database_name = "agora_authentication"
      extensions    = "plpgsql,uuid-ossp"
      object_key    = "authentication"
      owner         = "agora_authentication"
      port          = 5433
      restore_cron  = "45 3 1 * *"
      secret_id     = "production-authentication-postgres-backup-password"
    }
    json_keys = {
      backup_cron   = "15 */4 * * *"
      backup_role   = "agora_json_keys_backup"
      database_name = "agora_json_keys"
      extensions    = "plpgsql,uuid-ossp"
      object_key    = "json-keys"
      owner         = "agora_json_keys"
      port          = 5432
      restore_cron  = "15 3 1 * *"
      secret_id     = "production-json-keys-postgres-backup-password"
    }
  }

  enabled_database_contracts = {
    for key, release in var.database_releases : key => merge(
      local.database_contracts[key],
      release,
    )
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
