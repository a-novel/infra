resource "google_project_iam_custom_role" "foundation_service_access" {
  count = contains(keys(local.service_release_boundaries), "authentication/public-api") ? 1 : 0

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
  permissions = ["run.services.get", "run.services.update", "run.jobs.get", "run.jobs.update"]
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
