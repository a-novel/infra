resource "google_project_iam_custom_role" "foundation_service_access" {
  count = anytrue([for key in ["authentication/public-api", "json-keys/private"] : contains(keys(local.service_release_boundaries), key)]) ? 1 : 0

  project     = google_project.workload.project_id
  role_id     = "infraFoundationServiceAccess"
  title       = "Foundation Cloud Run service access"
  description = "Manage invocation policies on the tagged internal services."
  permissions = ["run.services.getIamPolicy", "run.services.setIamPolicy"]
}

resource "google_project_iam_member" "foundation_service_access" {
  count = length(google_project_iam_custom_role.foundation_service_access)

  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_service_access[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"

  condition {
    title       = "InternalCloudRunOnly"
    description = "Foundation may manage invocation only on tagged private internal services."
    expression  = "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["internal"].id}')"
  }
}

# Creation cannot be scoped. Cloud Run and Cloud Scheduler support no resource-name conditions, and
# a resource that does not exist yet carries no tag. A new service's first deploy creates its jobs
# without an execution and its services without invokers. Foundation then tags them and creates
# their schedules. Only tagged resources can be updated, run or invoked. Listing tag bindings is
# unscoped too: the deploy reads a binding back before the release role's conditions see its tag.
resource "google_project_iam_custom_role" "foundation_private_provisioning" {
  count = length(google_project_iam_custom_role.foundation_private_release)

  project     = google_project.workload.project_id
  role_id     = "infraFoundationPrivateProvisioning"
  title       = "Foundation private workload creation"
  description = "Create and tag private Cloud Run services, jobs and schedules, and read them back, without updating, running or invoking them."
  permissions = [
    "cloudscheduler.jobs.create",
    "run.jobs.create", "run.jobs.createTagBinding", "run.jobs.get", "run.jobs.listTagBindings",
    "run.services.create", "run.services.createTagBinding",
    "run.services.get", "run.services.listTagBindings",
  ]
}

resource "google_project_iam_member" "foundation_private_provisioning" {
  count = length(google_project_iam_custom_role.foundation_private_provisioning)

  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_private_provisioning[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"
}

# Binding a tag also takes tagUser on its value, which the project's tagAdmin does not include.
resource "google_tags_tag_value_iam_member" "foundation_application_tags" {
  for_each = toset([for workload in values(local.application_invocation) : workload.class])

  tag_value = google_tags_tag_value.cloud_run_invocation[each.value].name
  role      = "roles/resourcemanager.tagUser"
  member    = "serviceAccount:${local.automation_service_accounts.foundation}"
}

resource "google_project_iam_custom_role" "foundation_public_api" {
  count = anytrue([for boundary in local.service_release_boundaries : boundary.zone == "public-api"]) ? 1 : 0

  project     = var.public_api_project_id
  role_id     = "infraFoundationPublicAPI"
  title       = "Foundation public API deployment"
  description = "Create and update Cloud Run APIs through protected native plans."
  permissions = ["run.services.create", "run.services.update"]

  depends_on = [module.public_api_project]
}

resource "google_project_iam_custom_role" "foundation_private_release" {
  count = anytrue([for boundary in local.service_release_boundaries : boundary.zone == "private"]) ? 1 : 0

  project     = google_project.workload.project_id
  role_id     = "infraFoundationPrivateRelease"
  title       = "Foundation private workload updates"
  description = "Inspect and update existing private application definitions through protected native plans."
  permissions = [
    "run.services.get", "run.services.update", "run.services.listTagBindings",
    "run.jobs.get", "run.jobs.update", "run.jobs.listTagBindings",
  ]
}

resource "google_project_iam_member" "foundation_private_release" {
  count = length(google_project_iam_custom_role.foundation_private_release)

  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_private_release[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"

  condition {
    title       = "PrivateApplicationUpdatesOnly"
    description = "Existing internal APIs and application jobs only; backup safety jobs remain excluded."
    expression = "(${join(" || ", [for class in ["internal", "release", "scheduled"] :
      "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation[class].id}')"
    ])}) && !resource.matchTag('${var.workload_project_id}/agora-backup-maintenance', 'enabled')"
  }
}

# A release moves the maintenance job's image like any other job's, but only operators run it:
# foundation_release_jobs leaves its class out.
resource "google_project_iam_member" "foundation_maintenance_updates" {
  count = length(google_project_iam_custom_role.foundation_private_release)

  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_private_release[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"

  condition {
    title       = "MaintenanceJobUpdatesOnly"
    description = "The existing maintenance job only, never run."
    expression  = "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["maintenance"].id}')"
  }
}

resource "google_project_iam_member" "foundation_public_api" {
  count = length(google_project_iam_custom_role.foundation_public_api)

  project = var.public_api_project_id
  role    = google_project_iam_custom_role.foundation_public_api[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"
}

# Cloud Run requires invocation permission when a job update requests an execution.
resource "google_project_iam_custom_role" "foundation_release_jobs" {
  count       = length(google_project_iam_custom_role.foundation_private_release)
  project     = google_project.workload.project_id
  role_id     = "infraFoundationReleaseJobs"
  title       = "Foundation native release execution"
  description = "Run existing release jobs without overrides, cancellation or creation."
  permissions = ["run.jobs.run"]
}

resource "google_project_iam_member" "foundation_release_jobs" {
  count   = length(google_project_iam_custom_role.foundation_release_jobs)
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_release_jobs[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"

  condition {
    title       = "ReleaseJobsOnly"
    description = "Migration and application probe jobs; scheduled work, maintenance and backups are excluded."
    expression  = "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["release"].id}') && !resource.matchTag('${var.workload_project_id}/agora-backup-maintenance', 'enabled')"
  }
}

resource "google_project_iam_custom_role" "foundation_release_observation" {
  count       = length(google_project_iam_custom_role.foundation_private_release)
  project     = google_project.workload.project_id
  role_id     = "infraFoundationReleaseObservation"
  title       = "Foundation release observation"
  description = "Read native executions, Cloud Run operations and the rotation schedule around a release."
  # Operations sit outside the tagged services and jobs, so the tag conditions cannot cover them.
  permissions = ["run.executions.get", "run.executions.list", "run.operations.get", "cloudscheduler.jobs.get"]
}

resource "google_project_iam_member" "foundation_release_observation" {
  count   = length(google_project_iam_custom_role.foundation_release_observation)
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_release_observation[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"
}

# Scheduler supports no resource-name conditions for these permissions. OpenTofu replaces a schedule
# whose creation failed, and destroys it before it updates any role the schedule's state records as
# a dependency, the provisioning role included. This role holds what the replacement needs.
resource "google_project_iam_custom_role" "foundation_scheduler" {
  count       = contains(keys(local.service_release_boundaries), "json-keys/private") ? 1 : 0
  project     = google_project.workload.project_id
  role_id     = "infraFoundationScheduler"
  title       = "Foundation existing schedule updates"
  description = "Read, update, resume and delete existing schedules without creating or running jobs."
  permissions = [
    "cloudscheduler.jobs.delete", "cloudscheduler.jobs.enable",
    "cloudscheduler.jobs.get", "cloudscheduler.jobs.fullView", "cloudscheduler.jobs.update",
  ]
}

resource "google_project_iam_member" "foundation_scheduler" {
  count   = length(google_project_iam_custom_role.foundation_scheduler)
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_scheduler[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"
}

resource "google_service_account_iam_member" "foundation_scheduler_act_as" {
  count              = length(google_project_iam_custom_role.foundation_scheduler)
  service_account_id = google_service_account.runtime["scheduler_invoker"].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.automation_service_accounts.foundation}"
}

resource "google_project_service" "public_api_telemetry" {
  for_each = length(google_project_iam_custom_role.foundation_public_api) == 0 ? toset([]) : toset([
    "cloudtrace.googleapis.com", "telemetry.googleapis.com",
  ])

  project                    = var.public_api_project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false

  depends_on = [module.public_api_project]
}

resource "google_project_iam_member" "public_api_network_viewer" {
  count = length(google_project_iam_custom_role.foundation_public_api)

  project = google_compute_shared_vpc_service_project.public_api["public-api"].host_project
  role    = "roles/compute.networkViewer"
  member  = module.public_api_project["public-api"].service_agents["run.googleapis.com"]
}

resource "google_compute_subnetwork_iam_member" "public_api_run" {
  count = length(google_project_iam_custom_role.foundation_public_api)

  project    = google_compute_shared_vpc_service_project.public_api["public-api"].host_project
  region     = var.region
  subnetwork = google_compute_subnetwork.production.name
  role       = "roles/compute.networkUser"
  member     = module.public_api_project["public-api"].service_agents["run.googleapis.com"]
}
