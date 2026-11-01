resource "google_project_iam_custom_role" "foundation_public_api" {
  count = anytrue([for boundary in local.service_release_boundaries : boundary.zone == "public-api"]) ? 1 : 0

  project     = var.public_api_project_id
  role_id     = "infraFoundationPublicAPI"
  title       = "Foundation public API deployment"
  description = "Create, update and retire Cloud Run APIs through protected native plans."
  permissions = ["run.services.create", "run.services.update", "run.services.delete"]

  depends_on = [module.public_api_project]
}

# Platforms serve from the public project on their Cloud Run URLs.
resource "google_project_iam_custom_role" "foundation_public_platforms" {
  project     = var.public_project_id
  role_id     = "infraFoundationPublicPlatforms"
  title       = "Foundation platform deployment"
  description = "Create, update and retire the platforms' Cloud Run services through protected native plans."
  permissions = ["run.services.create", "run.services.update", "run.services.delete"]

  depends_on = [module.public_project]
}

resource "google_project_iam_member" "foundation_public_platforms" {
  project = var.public_project_id
  role    = google_project_iam_custom_role.foundation_public_platforms.name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"
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

  project = google_compute_shared_vpc_service_project.public_api.host_project
  role    = "roles/compute.networkViewer"
  member  = module.public_api_project["public-api"].service_agents["run.googleapis.com"]
}

resource "google_compute_subnetwork_iam_member" "public_api_run" {
  count = length(google_project_iam_custom_role.foundation_public_api)

  project    = google_compute_shared_vpc_service_project.public_api.host_project
  region     = var.region
  subnetwork = google_compute_subnetwork.production.name
  role       = "roles/compute.networkUser"
  member     = module.public_api_project["public-api"].service_agents["run.googleapis.com"]
}

# Authentication's REST API reaches the internet from the egress subnet.
resource "google_compute_subnetwork_iam_member" "public_api_run_egress" {
  count = length(google_project_iam_custom_role.foundation_public_api)

  project    = google_compute_shared_vpc_service_project.public_api.host_project
  region     = var.region
  subnetwork = google_compute_subnetwork.egress.name
  role       = "roles/compute.networkUser"
  member     = module.public_api_project["public-api"].service_agents["run.googleapis.com"]
}
