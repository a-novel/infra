locals {
  # A retiring container is listed here: one apply unlocks it, and the next deletes it once its
  # definition goes.
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

# Sentry retired (a-novel/infra#1215). The previous apply unlocked these containers; moving them out
# of the protected resource lets this one delete them. Remove these blocks once applied.
moved {
  from = google_secret_manager_secret.application["production-sentry-plan-token"]
  to   = google_secret_manager_secret.retired["production-sentry-plan-token"]
}

moved {
  from = google_secret_manager_secret.application["production-sentry-deploy-token"]
  to   = google_secret_manager_secret.retired["production-sentry-deploy-token"]
}

removed {
  from = google_secret_manager_secret.retired

  lifecycle {
    destroy = true
  }
}

# The plan and deploy identities' grants on those tokens leave with them.
removed {
  from = google_secret_manager_secret_iam_member.sentry_token

  lifecycle {
    destroy = false
  }
}

resource "google_secret_manager_secret_iam_member" "operator" {
  for_each = local.operator_secret_bindings

  project   = var.management_project_id
  secret_id = google_secret_manager_secret.application[each.value.secret].secret_id
  role      = each.value.role
  member    = each.value.principal
}
