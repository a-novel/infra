provider "google" {
  # Authentication starts in the stable management project because the
  # replaceable workload project might not exist yet.
  project = var.management_project_id
  region  = var.region

  default_labels = local.labels
}

locals {
  root_name = "foundation"

  labels = {
    application = "agora"
    environment = "production"
    managed-by  = "opentofu"
    plane       = "workload"
  }

  required_services = toset([
    "artifactregistry.googleapis.com",
    "cloudquotas.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "serviceusage.googleapis.com",
  ])
}

resource "google_project" "workload" {
  name            = var.workload_project_name
  project_id      = var.workload_project_id
  billing_account = var.billing_account_id
  org_id          = var.folder_id == null ? var.organization_id : null
  folder_id       = var.folder_id

  # Google initially creates a default VPC; the provider deletes that empty
  # network before this resource completes so only the reviewed custom VPC remains.
  auto_create_network = false
  deletion_policy     = "PREVENT"
  labels              = local.labels

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = var.organization_id == null || var.folder_id == null
      error_message = "Set at most one of organization_id or folder_id."
    }
  }
}

resource "google_project_service" "workload" {
  for_each = local.required_services

  project = google_project.workload.project_id
  service = each.value

  # Removing code must not disable an API that a recovery path still needs.
  disable_dependent_services = false
  disable_on_destroy         = false
}
