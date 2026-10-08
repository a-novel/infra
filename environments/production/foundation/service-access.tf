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
    description = "Migration and application probe jobs; scheduled work, initialization and backups are excluded."
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

# Scheduler does not support resource-name conditions for these permissions.
resource "google_project_iam_custom_role" "foundation_scheduler" {
  count       = contains(keys(local.service_release_boundaries), "json-keys/private") ? 1 : 0
  project     = google_project.workload.project_id
  role_id     = "infraFoundationScheduler"
  title       = "Foundation existing schedule updates"
  description = "Read and update existing schedules without creating, deleting or running jobs."
  permissions = ["cloudscheduler.jobs.get", "cloudscheduler.jobs.fullView", "cloudscheduler.jobs.update"]
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
