variable "service_release_zones" {
  description = "Service/zone registration and private custody folders in shared production projects; runtime resources use the service roots."
  type        = map(set(string))
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([for service, zones in var.service_release_zones :
      contains(["json-keys", "authentication"], service) && zones != null &&
      try(length(zones) > 0 && alltrue([for zone in zones : contains(["private", "public-api"], zone)]), false)
    ])
    error_message = "Select nonempty private/public-api zone sets for JSON Keys or Authentication; public is reserved for platforms."
  }

  validation {
    condition = length(var.service_release_zones) == 0 || (
      var.shared_vpc_enabled &&
      length(var.service_projects) == 0 &&
      (var.public_api_project_id != null || alltrue([for zones in var.service_release_zones : !try(contains(zones, "public-api"), false)]))
    )
    error_message = "Shared release boundaries require explicit Shared VPC, an API shell for public-api selections, and no dedicated-service selection."
  }
}

locals {
  service_release_boundaries = {
    for boundary in flatten([for service, zones in var.service_release_zones : [
      for zone in coalesce(zones, toset([])) : { service = service, zone = zone }
    ]]) : "${boundary.service}/${boundary.zone}" => boundary
    if contains(["private", "public-api"], boundary.zone) && (boundary.zone != "public-api" || var.public_api_project_id != null)
  }
}

module "service_release" {
  source   = "../../../modules/service-custody"
  for_each = local.service_release_boundaries

  project_id           = each.value.zone == "private" ? google_project.workload.project_id : module.public_api_project["public-api"].project_id
  zone                 = each.value.zone
  labels               = merge(local.labels, { service = each.value.service })
  plan_service_account = local.automation_service_accounts.plan
  management = {
    project_id     = var.management_project_id
    project_number = data.google_project.management[0].number
  }

  depends_on = [google_project_service.workload["iam.googleapis.com"], module.public_api_project]
}

output "service_release_boundaries" {
  description = "Private service/zone custody coordinates. Null when no service is registered."
  value       = length(module.service_release) == 0 ? null : { for key, boundary in module.service_release : key => boundary.release }
}
