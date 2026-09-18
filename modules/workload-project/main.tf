resource "google_project" "service" {
  project_id          = var.project_id
  name                = var.project_id
  billing_account     = var.billing_account_id
  org_id              = var.organization_id
  folder_id           = var.folder_id
  auto_create_network = false
  deletion_policy     = "PREVENT"
  labels              = var.labels

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = (var.organization_id != null) != (var.folder_id != null)
      error_message = "Service projects require exactly one organization or folder parent."
    }
  }
}

resource "google_project_service" "api" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "cloudquotas.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "oslogin.googleapis.com",
    "run.googleapis.com",
    "serviceusage.googleapis.com",
  ])

  project                    = google_project.service.project_id
  service                    = each.value
  disable_on_destroy         = false
  disable_dependent_services = false
}

resource "google_project_default_service_accounts" "service" {
  project = google_project.service.project_id
  action  = "DEPRIVILEGE"

  depends_on = [google_project_service.api]
}

# Project creation grants the creator Owner. These bindings allow the human
# operator to remove that temporary grant after verifying convergence.
resource "google_project_iam_member" "foundation" {
  for_each = toset([
    "roles/compute.networkAdmin",
    "roles/iam.roleAdmin",
    "roles/logging.configWriter",
    "roles/resourcemanager.projectIamAdmin",
    "roles/serviceusage.serviceUsageAdmin",
  ])

  project = google_project.service.project_id
  role    = each.value
  member  = "serviceAccount:${var.foundation_service_account}"
}

resource "google_project_iam_custom_role" "metadata" {
  project     = google_project.service.project_id
  role_id     = "foundationProjectMetadata"
  title       = "Foundation project metadata"
  description = "Maintain project labels and inspect default identities without project deletion or movement."
  permissions = [
    "iam.serviceAccounts.list",
    "resourcemanager.projects.get",
    "resourcemanager.projects.update",
  ]

  depends_on = [google_project_service.api["iam.googleapis.com"]]
}

resource "google_project_iam_member" "metadata" {
  project = google_project.service.project_id
  role    = google_project_iam_custom_role.metadata.name
  member  = "serviceAccount:${var.foundation_service_account}"
}

resource "google_project_iam_member" "plan" {
  project = google_project.service.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${var.plan_service_account}"
}

resource "google_logging_project_bucket_config" "default" {
  project         = google_project.service.project_id
  location        = "global"
  bucket_id       = "_Default"
  retention_days  = 30
  deletion_policy = "PREVENT"

  depends_on = [google_project_service.api["logging.googleapis.com"]]
}
