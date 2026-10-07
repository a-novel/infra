# Separate only the retired logical credentials so active secrets keep all deletion guards.
# Apply this protection change before removing these two containers in the next cleanup.
locals {
  retiring_backup_secrets = {
    production-authentication-postgres-backup-password = "Authentication database read-only backup password"
    production-json-keys-postgres-backup-password      = "JSON Keys database read-only backup password"
  }
}

moved {
  from = google_secret_manager_secret.application["production-authentication-postgres-backup-password"]
  to   = google_secret_manager_secret.retiring_backup["production-authentication-postgres-backup-password"]
}

moved {
  from = google_secret_manager_secret.application["production-json-keys-postgres-backup-password"]
  to   = google_secret_manager_secret.retiring_backup["production-json-keys-postgres-backup-password"]
}

resource "google_secret_manager_secret" "retiring_backup" {
  for_each = local.retiring_backup_secrets

  secret_id = each.key
  annotations = {
    contract = "POSTGRES_BACKUP_PASSWORD"
    purpose  = each.value
  }
  replication {
    auto {}
  }

  version_destroy_ttl = "2592000s"
  deletion_protection = false
  deletion_policy     = "DELETE"
}
