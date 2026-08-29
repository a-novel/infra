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
    recovery    = var.recovery_mode ? "true" : "false"
  }

  required_services = toset([
    "artifactregistry.googleapis.com",
    "cloudscheduler.googleapis.com",
    "cloudquotas.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "oslogin.googleapis.com",
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

    precondition {
      condition = (
        var.adopt_existing_project ||
        var.organization_id != null ||
        var.folder_id != null
      )
      error_message = "Set adopt_existing_project when neither organization_id nor folder_id is configured."
    }
  }
}

# Adopt either the standalone project's human-created shell or a project that
# Google created before an interrupted apply could persist it to remote state.
# The import remains inside the saved-plan review/apply boundary.
import {
  for_each = var.adopt_existing_project ? toset([var.workload_project_id]) : toset([])

  to = google_project.workload
  id = each.value
}

resource "google_project_service" "workload" {
  for_each = local.required_services

  project = google_project.workload.project_id
  service = each.value

  # Removing code must not disable an API that a recovery path still needs.
  disable_dependent_services = false
  disable_on_destroy         = false
}
