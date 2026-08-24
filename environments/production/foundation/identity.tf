locals {
  automation_service_accounts = {
    foundation = "infra-foundation@${var.management_project_id}.iam.gserviceaccount.com"
    plan       = "infra-plan@${var.management_project_id}.iam.gserviceaccount.com"
    recovery   = "infra-recovery@${var.management_project_id}.iam.gserviceaccount.com"
    release    = "infra-release@${var.management_project_id}.iam.gserviceaccount.com"
  }

  runtime_identities = {
    authentication = {
      account_id   = "agora-authentication"
      display_name = "Agora Authentication runtime"
    }
    backup = {
      account_id   = "agora-backup"
      display_name = "Agora PostgreSQL backup"
    }
    database = {
      account_id   = "agora-database-host"
      display_name = "Agora PostgreSQL host"
    }
    json_keys = {
      account_id   = "agora-json-keys"
      display_name = "Agora JSON Keys runtime"
    }
    restore = {
      account_id   = "agora-restore"
      display_name = "Agora PostgreSQL restore"
    }
    scheduler_invoker = {
      account_id   = "agora-scheduler-invoker"
      display_name = "Agora scheduled job invoker"
    }
  }

  foundation_project_roles = toset([
    "roles/artifactregistry.admin",
    "roles/billing.projectManager",
    "roles/cloudquotas.admin",
    "roles/compute.networkAdmin",
    "roles/dns.admin",
    "roles/iam.roleAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/logging.configWriter",
    "roles/monitoring.notificationChannelEditor",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.serviceUsageAdmin",
  ])

  runtime_secret_access = {
    "authentication:postgres-dsn" = {
      identity = "authentication"
      secret   = "production-authentication-postgres-dsn"
    }
    "authentication:smtp-password" = {
      identity = "authentication"
      secret   = "production-authentication-smtp-sender-password"
    }
    "authentication:super-admin-password" = {
      identity = "authentication"
      secret   = "production-authentication-super-admin-password"
    }
    "database:authentication-password" = {
      identity = "database"
      secret   = "production-authentication-postgres-password"
    }
    "database:json-keys-password" = {
      identity = "database"
      secret   = "production-json-keys-postgres-password"
    }
    "json-keys:app-master-key" = {
      identity = "json_keys"
      secret   = "production-json-keys-app-master-key"
    }
    "json-keys:postgres-dsn" = {
      identity = "json_keys"
      secret   = "production-json-keys-postgres-dsn"
    }
  }
}

resource "google_project_iam_custom_role" "foundation_project_metadata" {
  project = google_project.workload.project_id

  role_id     = "infraFoundationProjectMetadata"
  title       = "Infra Foundation Project Metadata"
  description = "Maintain the workload project name and labels without project deletion or movement authority."
  stage       = "GA"

  permissions = [
    "resourcemanager.projects.get",
    "resourcemanager.projects.list",
    "resourcemanager.projects.update",
  ]

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "foundation" {
  for_each = local.foundation_project_roles

  project = google_project.workload.project_id
  role    = each.value
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"
}

resource "google_project_iam_member" "foundation_project_metadata" {
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_project_metadata.name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"
}

# Compute API activation can grant Editor to its default service account in
# projects without the preventive organization policy. Keep the account
# recoverable while removing its project roles.
resource "google_project_default_service_accounts" "workload" {
  project = google_project.workload.project_id
  action  = "DEPRIVILEGE"

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
}

resource "google_service_account" "runtime" {
  for_each = local.runtime_identities

  project      = google_project.workload.project_id
  account_id   = each.value.account_id
  display_name = each.value.display_name
  description  = "Keyless production identity for the ${replace(each.key, "_", " ")} boundary."

  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

# Secret payloads stay outside OpenTofu. These additive bindings expose only
# the exact pre-created container each runtime contract consumes.
resource "google_secret_manager_secret_iam_member" "runtime" {
  for_each = local.runtime_secret_access

  project   = var.management_project_id
  secret_id = each.value.secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime[each.value.identity].email}"
}
