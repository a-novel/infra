locals {
  pgbackrest_tls_endpoints = {
    ca = {
      contract = "PGBACKREST_CA_PEM"
      purpose  = "native backup public TLS trust bundle"
      readers  = ["database", "repository"]
    }
    database = {
      contract = "PGBACKREST_IDENTITY_PEM"
      purpose  = "database TLS client certificate and private key"
      readers  = ["database"]
    }
    repository = {
      contract = "PGBACKREST_IDENTITY_PEM"
      purpose  = "repository TLS server certificate and private key"
      readers  = ["repository"]
    }
  }

  pgbackrest_tls = merge([for service, config in var.native_backups : {
    for endpoint, credential in local.pgbackrest_tls_endpoints : "production-${service}-pgbackrest-${endpoint}" => {
      contract = credential.contract
      purpose  = "${service} ${credential.purpose}"
      service  = service
      endpoint = endpoint
      readers = [for reader in credential.readers :
        "${reader == "database" ? "agora-${service}-database" : "agora-pgbr-${service}"}@${config.workload_project_id}.iam.gserviceaccount.com"
      ]
    }
  } if config.tls_credentials]...)

  pgbackrest_tls_readers = merge([for secret, credential in local.pgbackrest_tls : {
    for reader in credential.readers : "${credential.service}:${credential.endpoint}:${split("@", reader)[0]}" => {
      secret = secret
      reader = reader
    }
  }]...)
}

resource "google_secret_manager_secret_iam_member" "pgbackrest_tls" {
  for_each = local.pgbackrest_tls_readers

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value.secret].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${each.value.reader}"
}
