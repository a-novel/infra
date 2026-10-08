variable "service_release_zones" {
  description = "Trust zones each service runs in; the service roots own the workloads."
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
      (var.public_api_project_id != null || alltrue([for zones in var.service_release_zones : !try(contains(zones, "public-api"), false)]))
    )
    error_message = "Service zones require the Shared VPC and, for public-api, the API project."
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

# The retired release tooling kept plans and receipts in these folders. They
# still hold historical objects, so OpenTofu forgets them instead of deleting.
removed {
  from = module.service_release

  lifecycle {
    destroy = false
  }
}
