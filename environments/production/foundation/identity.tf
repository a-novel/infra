locals {
  automation_service_accounts = {
    foundation = "infra-foundation@${var.management_project_id}.iam.gserviceaccount.com"
    plan       = "infra-plan@${var.management_project_id}.iam.gserviceaccount.com"
  }

  runtime_identities = {
    authentication_database = {
      account_id   = "agora-auth-database"
      display_name = "A-Novel Authentication PostgreSQL host"
    }
    json_keys_database = {
      account_id   = "agora-json-keys-database"
      display_name = "A-Novel JSON Keys PostgreSQL host"
    }
    genai_database = {
      account_id   = "agora-genai-database"
      display_name = "A-Novel GenAI PostgreSQL host"
    }
    scheduler_invoker = {
      account_id   = "agora-scheduler-invoker"
      display_name = "A-Novel scheduled job invoker"
    }
    cluster_nodes = {
      account_id   = "a-novel-cluster-nodes"
      display_name = "A-Novel cluster nodes"
    }
  }

  foundation_project_roles = toset([
    "roles/artifactregistry.admin",
    "roles/billing.projectManager",
    "roles/certificatemanager.editor",
    "roles/cloudquotas.admin",
    "roles/compute.instanceAdmin.v1",
    "roles/container.admin",
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

  cloud_run_invocation_tag_values = {
    internal = {
      short_name  = "internal"
      description = "Private service-to-service invocation."
    }
    maintenance = {
      short_name  = "maintenance"
      description = "Human-run maintenance operations, passed as execution arguments."
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

  # The cluster viewer role only finds the cluster and connects to it. The cluster root lets the
  # operators read the services' namespaces.
  database_operator_project_roles = toset([
    "roles/container.clusterViewer",
    "roles/compute.viewer",
    "roles/logging.viewer",
    "roles/monitoring.alertPolicyViewer",
    "roles/monitoring.alertViewer",
    "roles/serviceusage.serviceUsageConsumer",
  ])

  database_operator_project_bindings = {
    for binding in setproduct(var.database_operator_principals, local.database_operator_project_roles) :
    "${binding[0]}:${binding[1]}" => {
      principal = binding[0]
      role      = binding[1]
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

# Pull-request and drift plans read the project's configuration as the plan identity, which
# holds no data-access role.
resource "google_project_iam_member" "plan_viewer" {
  project = google_project.workload.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${local.automation_service_accounts.plan}"
}

# The plan identity reads the cluster's objects through its DNS endpoint, but never its Secrets.
resource "google_project_iam_member" "plan_cluster_viewer" {
  project = google_project.workload.project_id
  role    = "roles/container.viewer"
  member  = "serviceAccount:${local.automation_service_accounts.plan}"
}

# Managed instance groups, the cluster's node pools included, act through Google's project service
# agent, which holds the group manager's service-agent role.
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

  # The old platform's identities retire with it (a-novel/infra#1208).
  deletion_policy = each.key == "cluster_nodes" ? "PREVENT" : "DELETE"

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
}

# The cluster's nodes write their own logs and metrics and pull images, and nothing else: each
# workload acts as its own identity through Workload Identity.
resource "google_project_iam_member" "cluster_nodes" {
  project = google_project.workload.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = google_service_account.runtime["cluster_nodes"].member
}

resource "google_service_account_iam_member" "foundation_cluster_nodes_act_as" {
  service_account_id = google_service_account.runtime["cluster_nodes"].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.automation_service_accounts.foundation}"
}

# The invocation tags authorize. Each caller holds one project-level grant conditioned on a tag
# value, so the class a workload is tagged with decides who may run or invoke it.
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

# Named humans run Authentication's maintenance job on the cluster: they connect to the control
# plane, the cluster root's RBAC lets them run the job, and they read the logs to follow the run.
resource "google_project_iam_member" "maintenance_observer" {
  for_each = {
    for binding in setproduct(var.authentication_maintenance_principals, ["roles/container.clusterViewer", "roles/logging.viewer"]) :
    "${binding[0]}:${binding[1]}" => { principal = binding[0], role = binding[1] }
  }

  project = google_project.workload.project_id
  role    = each.value.role
  member  = each.value.principal
}

resource "google_project_iam_member" "database_operator" {
  for_each = local.database_operator_project_bindings

  project = google_project.workload.project_id
  role    = each.value.role
  member  = each.value.principal
}

# Operators read the public API's logs too, the perimeter's violations included.
resource "google_project_iam_member" "database_operator_public_api_logs" {
  for_each = var.database_operator_principals

  project = module.public_api_project["public-api"].project_id
  role    = "roles/logging.viewer"
  member  = each.value
}

# The deploy identity's and the group manager's grants on the database host identities leave with
# those identities, so no host deletion in the same apply waits on them (a-novel/infra#1208).
removed {
  from = google_service_account_iam_member.foundation_database_act_as

  lifecycle {
    destroy = false
  }
}

removed {
  from = google_service_account_iam_member.mig_database_act_as

  lifecycle {
    destroy = false
  }
}
