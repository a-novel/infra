locals {
  pgbackrest_tls = try(var.json_keys_pgbackrest.tls_credentials, false) ? {
    ca = {
      contract = "PGBACKREST_CA_PEM"
      purpose  = "JSON Keys native backup public TLS trust bundle"
      readers  = ["agora-database", "agora-backup-repository"]
    }
    database = {
      contract = "PGBACKREST_IDENTITY_PEM"
      purpose  = "JSON Keys database TLS client certificate and private key"
      readers  = ["agora-database"]
    }
    repository = {
      contract = "PGBACKREST_IDENTITY_PEM"
      purpose  = "JSON Keys repository TLS server certificate and private key"
      readers  = ["agora-backup-repository"]
    }
  } : {}

  pgbackrest_tls_readers = merge([for endpoint, credential in local.pgbackrest_tls : {
    for reader in credential.readers : "${endpoint}:${reader}" => {
      secret = "production-json-keys-pgbackrest-${endpoint}"
      reader = reader
    }
  }]...)
}

resource "google_secret_manager_secret_iam_member" "pgbackrest_tls" {
  for_each = local.pgbackrest_tls_readers

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value.reader}@${var.json_keys_pgbackrest.workload_project_id}.iam.gserviceaccount.com"
}
