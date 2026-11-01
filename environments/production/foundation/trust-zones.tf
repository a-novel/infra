variable "public_api_project_id" {
  description = "Project of the public-api trust zone, attached to the workload project's Shared VPC."
  type        = string

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.public_api_project_id)) &&
      !contains([var.management_project_id, var.workload_project_id, var.public_project_id], var.public_api_project_id)
    )
    error_message = "The public-api project needs a valid ID of its own."
  }
}

variable "public_project_id" {
  description = "Project of the public trust zone, reserved for platforms, with no Shared VPC attachment."
  type        = string

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.public_project_id)) &&
      !contains([var.management_project_id, var.workload_project_id], var.public_project_id)
    )
    error_message = "The public project needs a valid ID distinct from the management and workload projects."
  }
}

module "public_project" {
  source = "../../../modules/project-shell"

  project_id                 = var.public_project_id
  billing_account_id         = var.billing_account_id
  organization_id            = var.organization_id
  folder_id                  = var.folder_id
  labels                     = merge(local.labels, { "trust-zone" = "public" })
  foundation_service_account = local.automation_service_accounts.foundation
  plan_service_account       = local.automation_service_accounts.plan
}

moved {
  from = module.public_project["public"]
  to   = module.public_project
}

# Keyed by zone: the perimeter lists its projects by iterating this module's instances.
module "public_api_project" {
  source   = "../../../modules/project-shell"
  for_each = { public-api = var.public_api_project_id }

  project_id                 = each.value
  billing_account_id         = var.billing_account_id
  organization_id            = var.organization_id
  folder_id                  = var.folder_id
  labels                     = merge(local.labels, { "trust-zone" = "public-api" })
  foundation_service_account = local.automation_service_accounts.foundation
  plan_service_account       = local.automation_service_accounts.plan
}

resource "google_compute_shared_vpc_host_project" "production" {
  project = google_project.workload.project_id
  # Retires with the public-api project, its only service project (a-novel/infra#1209).
  deletion_policy = "DELETE"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
}

moved {
  from = google_compute_shared_vpc_host_project.production[0]
  to   = google_compute_shared_vpc_host_project.production
}

resource "google_compute_shared_vpc_service_project" "public_api" {
  host_project    = google_compute_shared_vpc_host_project.production.project
  service_project = module.public_api_project["public-api"].project_id

  lifecycle {
    prevent_destroy = true
  }
}

moved {
  from = google_compute_shared_vpc_service_project.public_api["public-api"]
  to   = google_compute_shared_vpc_service_project.public_api
}

output "production_projects" {
  description = "Project ID and number of each trust zone's project, by zone."
  value = {
    private    = { project_id = google_project.workload.project_id, project_number = google_project.workload.number }
    public     = { project_id = module.public_project.project_id, project_number = module.public_project.project_number }
    public-api = { project_id = module.public_api_project["public-api"].project_id, project_number = module.public_api_project["public-api"].project_number }
  }
}
