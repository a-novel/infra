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
    authentication_initializer = {
      account_id   = "agora-auth-initializer"
      display_name = "Agora Authentication initializer"
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

  foundation_project_roles = setunion(toset([
    "roles/artifactregistry.admin",
    "roles/billing.projectManager",
    "roles/cloudquotas.admin",
    "roles/compute.instanceAdmin.v1",
    "roles/compute.networkAdmin",
    "roles/dns.admin",
    "roles/iam.roleAdmin",
    "roles/iam.serviceAccountAdmin",
    "roles/logging.configWriter",
    "roles/resourcemanager.projectIamAdmin",
    "roles/resourcemanager.tagAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    ]), var.recovery_mode ? toset([]) : toset([
    "roles/monitoring.alertPolicyEditor",
    "roles/monitoring.notificationChannelEditor",
  ]))

  database_runtime_project_roles = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  release_application_project_roles = var.recovery_mode ? toset([
    "roles/cloudquotas.viewer",
    ]) : toset([
    "roles/cloudscheduler.admin",
    "roles/cloudquotas.viewer",
  ])

  release_runtime_identities = var.recovery_mode ? toset([
    "authentication",
    "json_keys",
    "restore",
    ]) : toset([
    "authentication",
    "backup",
    "json_keys",
    "restore",
    "scheduler_invoker",
  ])

  cloud_run_invocation_tag_values = {
    initializer = {
      short_name  = "initializer"
      description = "Human-only one-time Authentication initialization."
    }
    internal = {
      short_name  = "internal"
      description = "Private service-to-service invocation."
    }
    recovery = {
      short_name  = "recovery"
      description = "Disposable clean-room recovery execution."
    }
    release = {
      short_name  = "release"
      description = "Protected release-only migration execution."
    }
    scheduled = {
      short_name  = "scheduled"
      description = "Protected release and scheduler execution."
    }
  }

  database_operator_project_roles = toset([
    "roles/compute.osAdminLogin",
    "roles/compute.viewer",
    "roles/logging.viewer",
    "roles/monitoring.alertPolicyViewer",
    "roles/serviceusage.serviceUsageConsumer",
  ])

  database_operator_project_bindings = {
    for binding in setproduct(var.database_operator_principals, local.database_operator_project_roles) :
    "${binding[0]}:${binding[1]}" => {
      principal = binding[0]
      role      = binding[1]
    }
  }

  runtime_secret_access = merge({
    "authentication:postgres-password" = {
      identity = "authentication"
      secret   = "production-authentication-postgres-password"
    }
    "authentication:smtp-password" = {
      identity = "authentication"
      secret   = "production-authentication-smtp-sender-password"
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
    "json-keys:app-master-key" = {
      identity = "json_keys"
      secret   = "production-json-keys-app-master-key"
    }
    "json-keys:postgres-password" = {
      identity = "json_keys"
      secret   = "production-json-keys-postgres-password"
    }
    }, var.recovery_mode ? {
    "restore:authentication-owner-password" = {
      identity = "restore"
      secret   = "production-authentication-postgres-password"
    }
    "restore:json-keys-owner-password" = {
      identity = "restore"
      secret   = "production-json-keys-postgres-password"
    }
    } : {
    "authentication-initializer:postgres-password" = {
      identity = "authentication_initializer"
      secret   = "production-authentication-postgres-password"
    }
    "authentication-initializer:super-admin-password" = {
      identity = "authentication_initializer"
      secret   = "production-authentication-super-admin-password"
    }
    "backup:authentication-backup-password" = {
      identity = "backup"
      secret   = "production-authentication-postgres-backup-password"
    }
    "backup:json-keys-backup-password" = {
      identity = "backup"
      secret   = "production-json-keys-postgres-backup-password"
    }
  })
}

resource "google_project_iam_custom_role" "foundation_project_metadata" {
  project = google_project.workload.project_id

  role_id     = "infraFoundationProjectMetadata"
  title       = "Infra Foundation Project Metadata"
  description = "Maintain the workload project name and labels without project deletion or movement authority."
  stage       = "GA"

  permissions = [
    "resourcemanager.projects.get",
    "resourcemanager.projects.update",
  ]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "foundation" {
  for_each = local.foundation_project_roles

  project = google_project.workload.project_id
  role    = each.value
  member  = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "foundation"]}"
}

resource "google_project_iam_member" "foundation_project_metadata" {
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_project_metadata.name
  member  = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "foundation"]}"
}

# The recovery identity may delete only the disposable project in which this
# binding exists. Production never grants project-deletion authority.
resource "google_project_iam_member" "recovery_project_deleter" {
  count = var.recovery_mode ? 1 : 0

  project = google_project.workload.project_id
  role    = "roles/resourcemanager.projectDeleter"
  member  = "serviceAccount:${local.automation_service_accounts.recovery}"
}

# The scheduled drift workflow reads provider metadata but cannot lock or
# write state and receives no data-access role. Recovery suffixes are inspected
# only during an incident, so they do not grant this production plan identity.
resource "google_project_iam_member" "plan_viewer" {
  count = var.recovery_mode ? 0 : 1

  project = google_project.workload.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${local.automation_service_accounts.plan}"
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

  deletion_policy = "DELETE"

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_service_account_iam_member" "foundation_database_act_as" {
  service_account_id = google_service_account.runtime["database"].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "foundation"]}"
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
  member             = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "release"]}"
}

# Resource Manager tags are authorization attributes here, not inventory
# labels. One project-level conditional binding replaces mutable per-job IAM
# while keeping each caller inside its reviewed workload class.
resource "google_tags_tag_key" "cloud_run_invocation" {
  parent      = "projects/${google_project.workload.number}"
  short_name  = "agora-invocation"
  description = "Cloud Run invocation boundary managed by OpenTofu."

  depends_on = [google_project_service.workload["cloudresourcemanager.googleapis.com"]]
}

resource "google_tags_tag_value" "cloud_run_invocation" {
  for_each = local.cloud_run_invocation_tag_values

  parent      = google_tags_tag_key.cloud_run_invocation.id
  short_name  = each.value.short_name
  description = each.value.description
}

resource "google_tags_tag_value_iam_member" "release_tag_user" {
  for_each = var.recovery_mode ? toset(["internal", "recovery"]) : toset(["internal", "release", "scheduled"])

  tag_value = google_tags_tag_value.cloud_run_invocation[each.value].name
  role      = "roles/resourcemanager.tagUser"
  member    = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "release"]}"
}

resource "google_tags_tag_value_iam_member" "initializer_tag_user" {
  for_each = var.recovery_mode ? toset([]) : var.authentication_initializer_principals

  tag_value = google_tags_tag_value.cloud_run_invocation["initializer"].name
  role      = "roles/resourcemanager.tagUser"
  member    = each.value
}

resource "google_project_iam_member" "release_cloud_run_invoker" {
  count = var.recovery_mode ? 0 : 1

  project = google_project.workload.project_id
  role    = "roles/run.jobsExecutor"
  member  = "serviceAccount:${local.automation_service_accounts.release}"

  condition {
    title       = "ReleaseTaggedCloudRunOnly"
    description = "Release may invoke only migration and scheduled operational workloads."
    expression = join(" || ", [
      "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["release"].id}')",
      "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["scheduled"].id}')",
    ])
  }
}

resource "google_project_iam_member" "scheduler_cloud_run_invoker" {
  count = var.recovery_mode ? 0 : 1

  project = google_project.workload.project_id
  role    = "roles/run.jobsExecutor"
  member  = "serviceAccount:${google_service_account.runtime["scheduler_invoker"].email}"

  condition {
    title       = "ScheduledCloudRunOnly"
    description = "Scheduler may invoke only explicitly tagged idempotent jobs."
    expression  = "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["scheduled"].id}')"
  }
}

resource "google_project_iam_member" "internal_cloud_run_invoker" {
  project = google_project.workload.project_id
  role    = "roles/run.servicesInvoker"
  member  = "serviceAccount:${google_service_account.runtime["authentication"].email}"

  condition {
    title       = "InternalCloudRunOnly"
    description = "Authentication may invoke only private internal services."
    expression  = "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["internal"].id}')"
  }
}

resource "google_project_iam_member" "recovery_cloud_run_invoker" {
  count = var.recovery_mode ? 1 : 0

  project = google_project.workload.project_id
  role    = "roles/run.jobsExecutor"
  member  = "serviceAccount:${local.automation_service_accounts.recovery}"

  condition {
    title       = "RecoveryTaggedCloudRunOnly"
    description = "Recovery automation may invoke only disposable recovery jobs."
    expression  = "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["recovery"].id}')"
  }
}

resource "google_project_iam_member" "recovery_smoke_cloud_run_invoker" {
  count = var.recovery_mode ? 1 : 0

  project = google_project.workload.project_id
  role    = "roles/run.servicesInvoker"
  member  = "serviceAccount:${google_service_account.runtime["database"].email}"

  condition {
    title       = "RecoverySmokeCloudRunOnly"
    description = "The disposable database host may invoke only tagged recovery services."
    expression  = "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["recovery"].id}')"
  }
}

resource "google_project_iam_member" "initializer_cloud_run_invoker" {
  for_each = var.recovery_mode ? toset([]) : var.authentication_initializer_principals

  project = google_project.workload.project_id
  role    = "roles/run.jobsExecutor"
  member  = each.value

  condition {
    title       = "AuthenticationInitializerOnly"
    description = "Named humans may invoke only the tagged one-time Authentication initializer."
    expression  = "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["initializer"].id}')"
  }
}

resource "google_service_account_iam_member" "initializer_act_as" {
  for_each = var.recovery_mode ? toset([]) : var.authentication_initializer_principals

  service_account_id = google_service_account.runtime["authentication_initializer"].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}

resource "google_project_iam_member" "release_application" {
  for_each = local.release_application_project_roles

  project = google_project.workload.project_id
  role    = each.value
  member  = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "release"]}"
}

# The release identity can reconcile definitions and approved tags. It cannot
# execute by role, override an execution, or read/change Cloud Run IAM policy.
resource "google_project_iam_custom_role" "release_cloud_run_deployer" {
  project = google_project.workload.project_id

  role_id     = "infraReleaseCloudRunDeployer"
  title       = "Infra Release Cloud Run Deployer"
  description = "Manage release-owned Cloud Run definitions and approved invocation tags without execution or IAM-policy authority."
  stage       = "GA"

  permissions = [
    "run.jobs.create",
    "run.jobs.createTagBinding",
    "run.jobs.delete",
    "run.jobs.deleteTagBinding",
    "run.jobs.get",
    "run.jobs.list",
    "run.jobs.listEffectiveTags",
    "run.jobs.listTagBindings",
    "run.jobs.update",
    "run.executions.get",
    "run.executions.list",
    "run.locations.list",
    "run.operations.get",
    "run.revisions.get",
    "run.revisions.list",
    "run.services.create",
    "run.services.createTagBinding",
    "run.services.delete",
    "run.services.deleteTagBinding",
    "run.services.get",
    "run.services.list",
    "run.services.listEffectiveTags",
    "run.services.listTagBindings",
    "run.services.update",
  ]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

# This role is assigned only to named humans. Execution remains a separate,
# initializer-tagged jobsExecutor grant, and overrides are never allowed.
resource "google_project_iam_custom_role" "authentication_initializer_deployer" {
  count = var.recovery_mode ? 0 : 1

  project = google_project.workload.project_id

  role_id     = "authenticationInitializerDeployer"
  title       = "Authentication Initializer Deployer"
  description = "Provision the human-only Authentication initializer without Cloud Run IAM-policy or execution-override authority."
  stage       = "GA"

  permissions = [
    "run.executions.get",
    "run.executions.list",
    "run.jobs.create",
    "run.jobs.createTagBinding",
    "run.jobs.delete",
    "run.jobs.deleteTagBinding",
    "run.jobs.get",
    "run.jobs.list",
    "run.jobs.listEffectiveTags",
    "run.jobs.listTagBindings",
    "run.jobs.update",
    "run.locations.list",
    "run.operations.get",
  ]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "authentication_initializer_deployer" {
  for_each = var.recovery_mode ? toset([]) : var.authentication_initializer_principals

  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.authentication_initializer_deployer[0].name
  member  = each.value
}

resource "google_project_iam_member" "release_cloud_run_deployer" {
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.release_cloud_run_deployer.name
  member  = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "release"]}"
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

# Compute authorizes an all-instances metadata patch against the group's full
# member specification. Separate bindings keep each supporting permission at
# the narrowest resource scope Compute exposes.
resource "google_project_iam_custom_role" "database_release" {
  project = google_project.workload.project_id

  role_id     = "infraDatabaseRelease"
  title       = "Infra Database Release"
  description = "Read recovery metadata and apply release metadata to an existing managed database instance."
  stage       = "GA"

  permissions = [
    "compute.autoscalers.list",
    "compute.instanceGroupManagers.get",
    "compute.instanceGroupManagers.update",
    "compute.snapshots.list",
    "compute.zoneOperations.get",
  ]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "database_release" {
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.database_release.name
  member  = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "release"]}"
}

resource "google_project_iam_custom_role" "database_release_member" {
  project = google_project.workload.project_id

  role_id     = "infraDatabaseReleaseMember"
  title       = "Infra Database Release Member"
  description = "Authorize the generated database VM and boot disk while applying group release metadata."
  stage       = "GA"

  permissions = [
    "compute.disks.create",
    "compute.instances.create",
    "compute.instances.setLabels",
    "compute.instances.setMetadata",
    "compute.instances.setTags",
  ]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "database_release_member" {
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.database_release_member.name
  member  = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "release"]}"

  condition {
    title       = "DatabaseReleaseMemberOnly"
    description = "Limit member authorization to generated database VMs and boot disks."
    expression = join(" || ", [
      "resource.type == 'compute.googleapis.com/Instance' && resource.name.startsWith('projects/${google_project.workload.project_id}/zones/${var.database_zone}/instances/agora-database-')",
      "resource.type == 'compute.googleapis.com/Disk' && resource.name.startsWith('projects/${google_project.workload.project_id}/zones/${var.database_zone}/disks/agora-database-')",
    ])
  }
}

resource "google_project_iam_custom_role" "database_release_data_disk" {
  project = google_project.workload.project_id

  role_id     = "infraDatabaseReleaseDataDisk"
  title       = "Infra Database Release Data Disk"
  description = "Attach the preserved database data disk while applying group release metadata."
  stage       = "GA"

  permissions = [
    "compute.disks.use",
  ]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_compute_disk_iam_member" "database_release" {
  project = google_project.workload.project_id
  zone    = var.database_zone
  name    = google_compute_disk.database.name
  role    = google_project_iam_custom_role.database_release_data_disk.name
  member  = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "release"]}"
}

resource "google_project_iam_custom_role" "database_release_template" {
  project = google_project.workload.project_id

  role_id     = "infraDatabaseReleaseTemplate"
  title       = "Infra Database Release Template"
  description = "Read the database instance template while applying group release metadata."
  stage       = "GA"

  permissions = [
    "compute.instanceTemplates.get",
    "compute.instanceTemplates.useReadOnly",
  ]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_compute_instance_template_iam_member" "database_release" {
  project = google_project.workload.project_id
  name    = google_compute_instance_template.database.name
  role    = google_project_iam_custom_role.database_release_template.name
  member  = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "release"]}"
}

# Stateful MIG patches authorize generated regional Address resources. Compute
# Address has no resource IAM policy or condition resource attributes, so this
# single-purpose project role is the narrowest available scope.
resource "google_project_iam_custom_role" "database_release_address" {
  project = google_project.workload.project_id

  role_id     = "infraDatabaseReleaseAddress"
  title       = "Infra Database Release Address"
  description = "Authorize stateful internal-address checks during database group metadata patches."
  stage       = "GA"

  permissions = [
    "compute.addresses.createInternal",
    "compute.addresses.deleteInternal",
    "compute.addresses.get",
    "compute.addresses.useInternal",
  ]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "database_release_address" {
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.database_release_address.name
  member  = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "release"]}"
}

resource "google_compute_subnetwork_iam_member" "database_release" {
  project    = google_project.workload.project_id
  region     = var.region
  subnetwork = google_compute_subnetwork.production.name
  role       = "roles/compute.networkUser"
  member     = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "release"]}"
}

# Secret payloads stay outside OpenTofu. These additive bindings expose only
# the exact pre-created container each runtime contract consumes.
resource "google_secret_manager_secret_iam_member" "runtime" {
  # Replacement-project CI cannot rewrite surviving management-plane IAM.
  # The recovery runbook grants these exact payload contracts as a human step.
  for_each = var.recovery_mode ? {} : local.runtime_secret_access

  project   = var.management_project_id
  secret_id = each.value.secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime[each.value.identity].email}"
}

# Logical backups are committed by a create-only identity. It cannot discover,
# read, overwrite, or delete a recovery point after the upload request returns.
resource "google_storage_bucket_iam_member" "backup_runtime_creator" {
  count = var.recovery_mode ? 0 : 1

  bucket = var.backup_bucket_name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.runtime["backup"].email}"
}

# Restore and freshness checks share one read-only identity. They can neither
# create a forged completion marker nor modify or delete retained data.
resource "google_storage_bucket_iam_member" "restore_runtime_viewer" {
  count = var.recovery_mode ? 0 : 1

  bucket = var.backup_bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.runtime["restore"].email}"
}
