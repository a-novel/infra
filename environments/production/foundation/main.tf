provider "google" {
  # Authentication starts in the stable management project because the
  # replaceable workload project might not exist yet.
  project = var.management_project_id
  region  = var.region

  default_labels = local.labels
}

# Only service-agent creation and the DNS allowlist's bypass rules need the beta provider.
provider "google-beta" {
  project = var.management_project_id
  region  = var.region
}

data "google_project" "management" {
  project_id = var.management_project_id
}

locals {
  labels = {
    application = "agora"
    environment = "production"
    managed-by  = "opentofu"
    plane       = "workload"
    recovery    = "false"
  }

  required_services = toset([
    "artifactregistry.googleapis.com",
    "certificatemanager.googleapis.com",
    "cloudscheduler.googleapis.com",
    "cloudquotas.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudtrace.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "networksecurity.googleapis.com",
    "oslogin.googleapis.com",
    "run.googleapis.com",
    "serviceusage.googleapis.com",
    "telemetry.googleapis.com",
  ])
}

resource "google_project" "workload" {
  name            = var.workload_project_name
  project_id      = var.workload_project_id
  billing_account = var.billing_account_id
  org_id          = var.folder_id == null ? var.organization_id : null
  folder_id       = var.folder_id

  # The provider deletes Google's default VPC while creating a project. An
  # imported project needs the explicit recovery resource declared separately.
  auto_create_network = false
  deletion_policy     = "PREVENT"
  labels              = local.labels

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = var.organization_id == null || var.folder_id == null
      error_message = "Set at most one of organization_id or folder_id."
    }

    precondition {
      condition     = var.organization_id != null || var.folder_id != null
      error_message = "Set organization_id or folder_id."
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
