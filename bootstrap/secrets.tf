locals {
  # The database owner passwords lost their last reader in a-novel/infra#925. This apply unlocks
  # them and drops their grants; the next one destroys them, since the provider reads
  # deletion_policy from state.
  retiring_secrets = toset([
    "production-authentication-postgres-password",
    "production-json-keys-postgres-password",
    "production-genai-postgres-password",
  ])

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

resource "google_secret_manager_secret_iam_member" "operator" {
  for_each = local.operator_secret_bindings

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value.secret].secret_id
  role      = each.value.role
  member    = each.value.principal
}
