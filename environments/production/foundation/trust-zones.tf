variable "shared_vpc_enabled" {
  description = "Retain the production Shared VPC host independently of service-project registration."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.recovery_mode || !var.shared_vpc_enabled
    error_message = "Disposable recovery must not enable a production Shared VPC host."
  }
}

variable "public_api_project_id" {
  description = "Optional production API project shell attached to the existing private Shared VPC; application access is separately granted."
  type        = string
  default     = null

  validation {
    condition = var.public_api_project_id == null || (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.public_api_project_id)) &&
      !contains([var.management_project_id, var.workload_project_id, var.public_project_id], var.public_api_project_id) &&
      !var.recovery_mode && var.shared_vpc_enabled &&
      length(var.service_projects) == 0
    )
    error_message = "The API shell requires a distinct valid project, an explicit production Shared VPC host, and no dedicated-service registration."
  }
}

variable "public_project_id" {
  description = "Optional production platform project shell with no private Shared VPC attachment; workload migration is separate."
  type        = string
  default     = null

  validation {
    condition = var.public_project_id == null || (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.public_project_id)) &&
      !contains([var.management_project_id, var.workload_project_id], var.public_project_id) &&
      !var.recovery_mode &&
      length(var.service_projects) == 0
    )
    error_message = "The platform shell requires a distinct valid project and no dedicated-service registration."
  }
}

module "public_project" {
  source   = "../../../modules/project-shell"
  for_each = var.public_project_id == null || var.recovery_mode ? {} : { public = var.public_project_id }

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
  for_each = var.public_api_project_id == null || var.recovery_mode ? {} : { public-api = var.public_api_project_id }

  project_id                 = each.value
  billing_account_id         = var.billing_account_id
  organization_id            = var.organization_id
  folder_id                  = var.folder_id
  labels                     = merge(local.labels, { "trust-zone" = "public-api" })
  foundation_service_account = local.automation_service_accounts.foundation
  plan_service_account       = local.automation_service_accounts.plan
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
  description = "Selected target trust-zone coordinates; these do not attest workload placement or authorize release writers. Null until a shell is selected."
  value = length(module.public_project) + length(module.public_api_project) == 0 ? null : merge(
    { private = { project_id = google_project.workload.project_id, project_number = google_project.workload.number } },
    { for zone, project in module.public_project : zone => { project_id = project.project_id, project_number = project.project_number } },
    { for zone, project in module.public_api_project : zone => { project_id = project.project_id, project_number = project.project_number } },
  )
}
