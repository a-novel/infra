locals {
  automation_service_accounts = {
    foundation = "infra-foundation@${var.management_project_id}.iam.gserviceaccount.com"
    plan       = "infra-plan@${var.management_project_id}.iam.gserviceaccount.com"
    recovery   = "infra-recovery@${var.management_project_id}.iam.gserviceaccount.com"
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
    authentication_database = {
      account_id   = "agora-auth-database"
      display_name = "Agora Authentication PostgreSQL host"
    }
    json_keys_database = {
      account_id   = "agora-json-keys-database"
      display_name = "Agora JSON Keys PostgreSQL host"
    }
    json_keys = {
      account_id   = "agora-json-keys"
      display_name = "Agora JSON Keys runtime"
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
    "roles/resourcemanager.projectIamAdmin",
    "roles/resourcemanager.tagAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/monitoring.alertPolicyEditor",
    "roles/monitoring.notificationChannelEditor",
  ])

  database_runtime_project_roles = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
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

  database_runtime_project_bindings = {
    for binding in setproduct(keys(local.database_hosts), local.database_runtime_project_roles) :
    "${binding[0]}:${binding[1]}" => {
      identity = local.database_hosts[binding[0]].identity
      role     = binding[1]
    }
  }

  database_operator_account_bindings = {
    for binding in setproduct(keys(local.database_hosts), var.database_operator_principals) :
    "${binding[0]}:${binding[1]}" => {
      identity  = local.database_hosts[binding[0]].identity
      principal = binding[1]
    }
  }

  runtime_secret_access = {
    "authentication:postgres-password" = {
      identity = "authentication"
      secret   = "production-authentication-postgres-password"
    }
    "authentication:smtp-password" = {
      identity = "authentication"
      secret   = "production-authentication-smtp-sender-password"
    }
    "database:authentication-password" = {
      identity = "authentication_database"
      secret   = "production-authentication-postgres-password"
    }
    "database:json-keys-password" = {
      identity = "json_keys_database"
      secret   = "production-json-keys-postgres-password"
    }
    "json-keys:app-master-key" = {
      identity = "json_keys"
      secret   = "production-json-keys-app-master-key"
    }
    "json-keys:postgres-password" = {
      identity = "json_keys"
      secret   = "production-json-keys-postgres-password"
    }
    "authentication:waitlist-secret" = {
      identity = "authentication"
      secret   = "production-authentication-waitlist-secret"
    }
    "authentication-initializer:postgres-password" = {
      identity = "authentication_initializer"
      secret   = "production-authentication-postgres-password"
    }
    "authentication-initializer:super-admin-password" = {
      identity = "authentication_initializer"
      secret   = "production-authentication-super-admin-password"
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
    "resourcemanager.projects.update",
  ]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
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

# The scheduled drift workflow reads provider metadata but cannot lock or
# write state and receives no data-access role.
resource "google_project_iam_member" "plan_viewer" {
  count = 1

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

  deletion_policy = "PREVENT"

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account_iam_member" "foundation_database_act_as" {
  for_each = local.database_hosts

  service_account_id = google_service_account.runtime[each.value.identity].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.automation_service_accounts.foundation}"
}

resource "google_service_account_iam_member" "mig_database_act_as" {
  for_each = local.database_hosts

  service_account_id = google_service_account.runtime[each.value.identity].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_project.workload.number}@cloudservices.gserviceaccount.com"
}

# Resource Manager tags are authorization attributes here, not inventory
# labels. One project-level conditional binding replaces mutable per-job IAM
# while keeping each caller inside its reviewed workload class.
resource "google_tags_tag_key" "cloud_run_invocation" {
  parent      = "projects/${google_project.workload.number}"
  short_name  = "agora-invocation"
  description = "Cloud Run invocation boundary managed by OpenTofu."

  depends_on = [google_project_service.workload["cloudresourcemanager.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_tags_tag_value" "cloud_run_invocation" {
  for_each = local.cloud_run_invocation_tag_values

  parent      = google_tags_tag_key.cloud_run_invocation.id
  short_name  = each.value.short_name
  description = each.value.description
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_tags_tag_value_iam_member" "initializer_tag_user" {
  for_each = var.authentication_initializer_principals

  tag_value = google_tags_tag_value.cloud_run_invocation["initializer"].name
  role      = "roles/resourcemanager.tagUser"
  member    = each.value
}

resource "google_project_iam_member" "scheduler_cloud_run_invoker" {
  count = 1

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

resource "google_project_iam_member" "initializer_cloud_run_invoker" {
  for_each = var.authentication_initializer_principals

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
  for_each = var.authentication_initializer_principals

  service_account_id = google_service_account.runtime["authentication_initializer"].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}

# This role is assigned only to named humans. Execution remains a separate,
# initializer-tagged jobsExecutor grant, and overrides are never allowed.
resource "google_project_iam_custom_role" "authentication_initializer_deployer" {
  count = 1

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
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_iam_member" "authentication_initializer_deployer" {
  for_each = var.authentication_initializer_principals

  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.authentication_initializer_deployer[0].name
  member  = each.value
}

resource "google_project_iam_member" "database_runtime_observability" {
  for_each = local.database_runtime_project_bindings

  project = google_project.workload.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.runtime[each.value.identity].email}"
}

resource "google_project_iam_member" "application_telemetry" {
  for_each = toset(["authentication", "json_keys"])

  project = google_project.workload.project_id
  role    = "roles/telemetry.writer"
  member  = "serviceAccount:${google_service_account.runtime[each.key].email}"
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
  for_each = local.database_operator_account_bindings

  service_account_id = google_service_account.runtime[each.value.identity].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value.principal
}

resource "google_service_account_iam_member" "repository_operator_act_as" {
  for_each = {
    for binding in setproduct(keys(local.pgbackrest_network), var.database_operator_principals) :
    "${binding[0]}:${binding[1]}" => { service = binding[0], principal = binding[1] }
    if try(contains(var.service_release_zones[binding[0]], "private"), false)
  }

  service_account_id = "projects/${var.workload_project_id}/serviceAccounts/${local.pgbackrest_network[each.value.service].repository}"
  role               = "roles/iam.serviceAccountUser"
  member             = each.value.principal
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
