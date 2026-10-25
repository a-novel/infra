variable "service_release_zones" {
  description = "Trust zones each service runs in; the service roots own the workloads."
  type        = map(set(string))
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([for service, zones in var.service_release_zones :
      contains(["json-keys", "authentication", "genai"], service) && zones != null &&
      try(length(zones) > 0 && alltrue([for zone in zones : contains(["private", "public-api"], zone)]), false)
    ])
    error_message = "Select nonempty private/public-api zone sets for JSON Keys, Authentication or GenAI; public is reserved for platforms."
  }
}

locals {
  service_release_boundaries = {
    for boundary in flatten([for service, zones in var.service_release_zones : [
      for zone in coalesce(zones, toset([])) : { service = service, zone = zone }
    ]]) : "${boundary.service}/${boundary.zone}" => boundary
    if contains(["private", "public-api"], boundary.zone)
  }
}
