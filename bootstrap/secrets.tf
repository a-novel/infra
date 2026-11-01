locals {
  # A retiring container is listed here, and one apply unlocks it. The next moves it out of the
  # protected resource to delete it.
  retiring_secrets = toset([])

  operator_secret_roles = toset([
    "roles/secretmanager.secretAccessor",
    "roles/secretmanager.secretVersionManager",
  ])

  operator_secret_bindings = {
    for binding in setproduct(setsubtract(keys(local.secret_definitions), local.retiring_secrets), var.operator_principals, local.operator_secret_roles) :
    "${binding[0]}:${binding[1]}:${binding[2]}" => {
      secret    = binding[0]
      principal = binding[1]
      role      = binding[2]
    }
  }
}

# Payload versions are entered outside OpenTofu so plans and state contain only
# these container names, annotations, and lifecycle settings.
resource "google_secret_manager_secret" "application" {
  for_each = local.secret_definitions

  secret_id = each.key

  annotations = {
    contract = each.value.contract
    purpose  = each.value.purpose
  }

  replication {
    auto {}
  }

  version_destroy_ttl = "2592000s"
  deletion_protection = !contains(local.retiring_secrets, each.key)
  deletion_policy     = contains(local.retiring_secrets, each.key) ? "DELETE" : "PREVENT"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["secretmanager.googleapis.com"]]
}

# The database hosts retired (a-novel/infra#1208). The previous apply unlocked their passwords and
# TLS credentials; moving them out of the protected resource lets this one delete them. Remove these
# blocks once applied.
moved {
  from = google_secret_manager_secret.application["production-authentication-app-password"]
  to   = google_secret_manager_secret.retired["production-authentication-app-password"]
}

moved {
  from = google_secret_manager_secret.application["production-json-keys-app-password"]
  to   = google_secret_manager_secret.retired["production-json-keys-app-password"]
}

moved {
  from = google_secret_manager_secret.application["production-genai-app-password"]
  to   = google_secret_manager_secret.retired["production-genai-app-password"]
}

moved {
  from = google_secret_manager_secret.application["production-json-keys-pgbackrest-ca"]
  to   = google_secret_manager_secret.retired["production-json-keys-pgbackrest-ca"]
}

moved {
  from = google_secret_manager_secret.application["production-json-keys-pgbackrest-database"]
  to   = google_secret_manager_secret.retired["production-json-keys-pgbackrest-database"]
}

moved {
  from = google_secret_manager_secret.application["production-json-keys-pgbackrest-repository"]
  to   = google_secret_manager_secret.retired["production-json-keys-pgbackrest-repository"]
}

moved {
  from = google_secret_manager_secret.application["production-authentication-pgbackrest-ca"]
  to   = google_secret_manager_secret.retired["production-authentication-pgbackrest-ca"]
}

moved {
  from = google_secret_manager_secret.application["production-authentication-pgbackrest-database"]
  to   = google_secret_manager_secret.retired["production-authentication-pgbackrest-database"]
}

moved {
  from = google_secret_manager_secret.application["production-authentication-pgbackrest-repository"]
  to   = google_secret_manager_secret.retired["production-authentication-pgbackrest-repository"]
}

moved {
  from = google_secret_manager_secret.application["production-genai-pgbackrest-ca"]
  to   = google_secret_manager_secret.retired["production-genai-pgbackrest-ca"]
}

moved {
  from = google_secret_manager_secret.application["production-genai-pgbackrest-database"]
  to   = google_secret_manager_secret.retired["production-genai-pgbackrest-database"]
}

moved {
  from = google_secret_manager_secret.application["production-genai-pgbackrest-repository"]
  to   = google_secret_manager_secret.retired["production-genai-pgbackrest-repository"]
}

removed {
  from = google_secret_manager_secret.retired

  lifecycle {
    destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "operator" {
  for_each = local.operator_secret_bindings

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value.secret].secret_id
  role      = each.value.role
  member    = each.value.principal
}
