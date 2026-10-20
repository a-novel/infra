variable "shared_vpc_enabled" {
  description = "Make the workload project the Shared VPC host that the public-api project attaches to."
  type        = bool
  default     = false
  nullable    = false
}

variable "public_api_project_id" {
  description = "Project of the public-api trust zone, attached to the workload project's Shared VPC. Null creates none."
  type        = string
  default     = null

  validation {
    condition = var.public_api_project_id == null || (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.public_api_project_id)) &&
      !contains([var.management_project_id, var.workload_project_id, var.public_project_id], var.public_api_project_id) &&
      var.shared_vpc_enabled
    )
    error_message = "The public-api project needs a valid ID of its own and the Shared VPC host."
  }
}

variable "public_project_id" {
  description = "Project of the public trust zone, reserved for platforms, with no Shared VPC attachment. Null creates none."
  type        = string
  default     = null

  validation {
    condition = var.public_project_id == null || (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.public_project_id)) &&
      !contains([var.management_project_id, var.workload_project_id], var.public_project_id)
    )
    error_message = "The public project needs a valid ID distinct from the management and workload projects."
  }
}

module "public_project" {
  source   = "../../../modules/project-shell"
  for_each = var.public_project_id == null ? {} : { public = var.public_project_id }

  project_id                 = each.value
  billing_account_id         = var.billing_account_id
  organization_id            = var.organization_id
  folder_id                  = var.folder_id
  labels                     = merge(local.labels, { "trust-zone" = "public" })
  foundation_service_account = local.automation_service_accounts.foundation
  plan_service_account       = local.automation_service_accounts.plan
}

module "public_api_project" {
  source   = "../../../modules/project-shell"
  for_each = var.public_api_project_id == null ? {} : { public-api = var.public_api_project_id }

  project_id                 = each.value
  billing_account_id         = var.billing_account_id
  organization_id            = var.organization_id
  folder_id                  = var.folder_id
  labels                     = merge(local.labels, { "trust-zone" = "public-api" })
  foundation_service_account = local.automation_service_accounts.foundation
  plan_service_account       = local.automation_service_accounts.plan
}

resource "google_compute_shared_vpc_host_project" "production" {
  count = var.shared_vpc_enabled ? 1 : 0

  project         = google_project.workload.project_id
  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
}

resource "google_compute_shared_vpc_service_project" "public_api" {
  for_each = module.public_api_project

  host_project    = google_project.workload.project_id
  service_project = each.value.project_id

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_compute_shared_vpc_host_project.production]
}

output "production_projects" {
  description = "Project ID and number of each trust zone's project, by zone. Null without a shell project."
  value = length(module.public_project) + length(module.public_api_project) == 0 ? null : merge(
    { private = { project_id = google_project.workload.project_id, project_number = google_project.workload.number } },
    { for zone, project in module.public_project : zone => { project_id = project.project_id, project_number = project.project_number } },
    { for zone, project in module.public_api_project : zone => { project_id = project.project_id, project_number = project.project_number } },
  )
}
