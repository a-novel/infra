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
    "roles/compute.instanceAdmin.v1",
    "roles/compute.networkAdmin",
    "roles/dns.admin",
    "roles/iam.roleAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/logging.configWriter",
    "roles/monitoring.alertPolicyEditor",
    "roles/monitoring.notificationChannelEditor",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.serviceUsageAdmin",
  ])

  database_runtime_project_roles = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  release_application_project_roles = toset([
    "roles/cloudscheduler.admin",
    "roles/run.developer",
  ])

  release_runtime_identities = toset([
    "authentication",
    "backup",
    "json_keys",
    "restore",
    "scheduler_invoker",
  ])

  database_operator_project_roles = toset([
    "roles/compute.osAdminLogin",
    "roles/compute.viewer",
  ])

  database_operator_project_bindings = {
    for binding in setproduct(var.database_operator_principals, local.database_operator_project_roles) :
    "${binding[0]}:${binding[1]}" => {
      principal = binding[0]
      role      = binding[1]
    }
  }

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
    "database:authentication-backup-password" = {
      identity = "database"
      secret   = "production-authentication-postgres-backup-password"
    }
    "database:json-keys-password" = {
      identity = "database"
      secret   = "production-json-keys-postgres-password"
    }
    "database:json-keys-backup-password" = {
      identity = "database"
      secret   = "production-json-keys-postgres-backup-password"
    }
    "backup:authentication-backup-password" = {
      identity = "backup"
      secret   = "production-authentication-postgres-backup-password"
    }
    "backup:json-keys-backup-password" = {
      identity = "backup"
      secret   = "production-json-keys-postgres-backup-password"
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

# Managed instance groups act through Google's project service agent. The
# service-agent role replaces a primitive Editor grant, while the account-level
# binding below permits only attachment of the dedicated database identity.
resource "google_project_iam_member" "mig_service_agent" {
  project = google_project.workload.project_id
  role    = "roles/compute.instanceGroupManagerServiceAgent"
  member  = "serviceAccount:${google_project.workload.number}@cloudservices.gserviceaccount.com"
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

resource "google_service_account_iam_member" "foundation_database_act_as" {
  service_account_id = google_service_account.runtime["database"].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.automation_service_accounts.foundation}"
}

resource "google_service_account_iam_member" "mig_database_act_as" {
  service_account_id = google_service_account.runtime["database"].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_project.workload.number}@cloudservices.gserviceaccount.com"
}

resource "google_service_account_iam_member" "release_runtime_act_as" {
  for_each = local.release_runtime_identities

  service_account_id = google_service_account.runtime[each.value].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.automation_service_accounts.release}"
}

resource "google_project_iam_member" "release_application" {
  for_each = local.release_application_project_roles

  project = google_project.workload.project_id
  role    = each.value
  member  = "serviceAccount:${local.automation_service_accounts.release}"
}

# Cloud Run Developer deliberately excludes policy writes. This two-permission
# supplement lets release manage IAM on its jobs without Cloud Run Admin; the
# reviewed release resources and tests constrain declared bindings to the
# scheduler identity's invoker role.
resource "google_project_iam_custom_role" "release_job_iam" {
  project = google_project.workload.project_id

  role_id     = "infraReleaseJobIam"
  title       = "Infra Release Job IAM"
  description = "Read and update IAM policies on release-managed Cloud Run jobs."
  stage       = "GA"

  permissions = [
    "run.jobs.getIamPolicy",
    "run.jobs.setIamPolicy",
  ]

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "release_job_iam" {
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.release_job_iam.name
  member  = "serviceAccount:${local.automation_service_accounts.release}"
}

# The private caller allowlist needs service IAM policy writes. Keep that
# authority separate from Cloud Run Admin, which also grants broad control-plane
# and execution permissions the release identity does not use.
resource "google_project_iam_custom_role" "release_service_iam" {
  project = google_project.workload.project_id

  role_id     = "infraReleaseServiceIam"
  title       = "Infra Release Service IAM"
  description = "Read and update IAM policies on release-managed Cloud Run services."
  stage       = "GA"

  permissions = [
    "run.services.getIamPolicy",
    "run.services.setIamPolicy",
  ]

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "release_service_iam" {
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.release_service_iam.name
  member  = "serviceAccount:${local.automation_service_accounts.release}"
}

resource "google_project_iam_member" "database_runtime_observability" {
  for_each = local.database_runtime_project_roles

  project = google_project.workload.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.runtime["database"].email}"
}

resource "google_project_iam_member" "database_operator" {
  for_each = local.database_operator_project_bindings

  project = google_project.workload.project_id
  role    = each.value.role
  member  = each.value.principal
}

resource "google_project_iam_member" "database_operator_iap" {
  for_each = var.database_operator_principals

  project = google_project.workload.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = each.value

  condition {
    title       = "DatabaseIAPSSHOnly"
    description = "Permit IAP TCP forwarding only to SSH; the VPC firewall limits the target to the database host."
    expression  = "destination.port == 22"
  }
}

# OS Login rechecks whether an SSH operator may act as the VM's attached
# service account. This account-level grant is required for login and does not
# grant token-minting authority.
resource "google_service_account_iam_member" "database_operator_act_as" {
  for_each = var.database_operator_principals

  service_account_id = google_service_account.runtime["database"].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}

# Google exposes one coarse update permission for all-instances metadata and
# broader MIG changes. Applying it to an existing member also requires one VM
# permission, setMetadata; the conditional binding below fences that permission
# to the generated database-name prefix. The fixed helper and protected
# environment remain the controls around the seven declared keys.
resource "google_project_iam_custom_role" "database_release" {
  project = google_project.workload.project_id

  role_id     = "infraDatabaseRelease"
  title       = "Infra Database Release"
  description = "Read recovery metadata and apply release metadata to an existing managed database instance."
  stage       = "GA"

  permissions = [
    "compute.instanceGroupManagers.get",
    "compute.instanceGroupManagers.update",
    "compute.instances.setMetadata",
    "compute.snapshots.list",
    "compute.zoneOperations.get",
  ]

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "database_release" {
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.database_release.name
  member  = "serviceAccount:${local.automation_service_accounts.release}"

  condition {
    title       = "DatabaseReleaseMemberOnly"
    description = "Fence the sole VM permission to generated members of the fixed database group."
    expression  = "resource.type != 'compute.googleapis.com/Instance' || resource.name.startsWith('projects/${google_project.workload.project_id}/zones/${var.database_zone}/instances/agora-database-')"
  }
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

# Logical backups are committed by a create-only identity. It cannot discover,
# read, overwrite, or delete a recovery point after the upload request returns.
resource "google_storage_bucket_iam_member" "backup_runtime_creator" {
  bucket = var.backup_bucket_name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.runtime["backup"].email}"
}

# Restore and freshness checks share one read-only identity. They can neither
# create a forged completion marker nor modify or delete retained data.
resource "google_storage_bucket_iam_member" "restore_runtime_viewer" {
  bucket = var.backup_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.runtime["restore"].email}"
}
