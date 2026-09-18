variable "service_projects" {
  description = "Service name to new project ID. Empty preserves the shared-project deployment."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for service, project in var.service_projects :
      can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", service)) &&
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", project)) &&
      !contains([var.management_project_id, var.workload_project_id], project)
    ]) && length(distinct(values(var.service_projects))) == length(var.service_projects)
    error_message = "Service names must be valid labels and project IDs must be valid, unique, and separate from management and the current workload project."
  }

  validation {
    condition     = !var.recovery_mode || length(var.service_projects) == 0
    error_message = "Recovery must not provision or attach production service projects."
  }
}

module "service_project" {
  source   = "../../../modules/workload-project"
  for_each = var.service_projects

  project_id                 = each.value
  billing_account_id         = var.billing_account_id
  organization_id            = var.organization_id
  folder_id                  = var.folder_id
  labels                     = merge(local.labels, { service = each.key })
  foundation_service_account = local.automation_service_accounts.foundation
  plan_service_account       = local.automation_service_accounts.plan
}

resource "google_compute_shared_vpc_host_project" "production" {
  count = length(var.service_projects) == 0 ? 0 : 1

  project         = google_project.workload.project_id
  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
}

resource "google_compute_shared_vpc_service_project" "service" {
  for_each = module.service_project

  host_project    = google_compute_shared_vpc_host_project.production[0].project
  service_project = each.value.project_id

  lifecycle {
    prevent_destroy = true
  }

  # Shared VPC attachment requires the service project's Compute API.
  depends_on = [module.service_project]
}

output "service_projects" {
  description = "Project coordinates only; attachment grants no subnet or application access."
  value = {
    for service, project in module.service_project : service => {
      project_id     = project.project_id
      project_number = project.project_number
      host_project   = google_compute_shared_vpc_service_project.service[service].host_project
    }
  }
}
