locals {
  operator_secret_roles = toset([
    "roles/secretmanager.secretAccessor",
    "roles/secretmanager.secretVersionManager",
  ])

  operator_secret_bindings = {
    for binding in setproduct(keys(local.secret_definitions), var.operator_principals, local.operator_secret_roles) :
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
  for_each = local.active_secret_definitions

  secret_id = each.key

  annotations = {
    contract = each.value.contract
    purpose  = each.value.purpose
  }

  replication {
    auto {}
  }

  version_destroy_ttl = "2592000s"
  deletion_protection = true
  deletion_policy     = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret" "retiring_application" {
  for_each = local.retiring_secret_definitions

  secret_id = each.key

  annotations = {
    contract = each.value.contract
    purpose  = each.value.purpose
  }

  replication {
    auto {}
  }

  version_destroy_ttl = "2592000s"
  deletion_protection = false
  deletion_policy     = "DELETE"

  depends_on = [google_project_service.management["secretmanager.googleapis.com"]]
}

moved {
  from = google_secret_manager_secret.application["production-authentication-postgres-dsn"]
  to   = google_secret_manager_secret.retiring_application["production-authentication-postgres-dsn"]
}

moved {
  from = google_secret_manager_secret.application["production-json-keys-postgres-dsn"]
  to   = google_secret_manager_secret.retiring_application["production-json-keys-postgres-dsn"]
}

locals {
  application_secret_ids = merge(
    { for name, secret in google_secret_manager_secret.application : name => secret.secret_id },
    { for name, secret in google_secret_manager_secret.retiring_application : name => secret.secret_id },
  )
}

resource "google_secret_manager_secret_iam_member" "operator" {
  for_each = local.operator_secret_bindings

  project   = var.management_project_id
  secret_id = local.application_secret_ids[each.value.secret]
  role      = each.value.role
  member    = each.value.principal
}
