variable "project_id" {
  description = "Existing destination project; this module does not create projects or runtime permissions."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Use a valid 6-30 character Google Cloud project ID."
  }
}

variable "labels" {
  description = "Owning service and environment."
  type        = map(string)
  validation {
    condition = (
      can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.labels.service)) &&
      can(regex("^[a-z][a-z0-9-]{0,15}$", var.labels.environment)) &&
      (var.zone == null || contains(["json-keys", "authentication"], var.labels.service))
    )
    error_message = "Provide valid service/environment labels; shared-zone enrollment supports only JSON Keys and Authentication."
  }
}

variable "zone" {
  description = "Shared trust zone; null preserves the dedicated-project identity and storage contract."
  type        = string
  default     = null
  validation {
    condition     = var.zone == null ? true : contains(["private", "public-api"], var.zone)
    error_message = "Select private or public-api, or leave null for the dedicated-project compatibility path."
  }
}

variable "management" {
  description = "Bootstrap-owned management project coordinates."
  type = object({
    project_id     = string
    project_number = string
  })
}

variable "plan_service_account" {
  description = "Read-only infrastructure assessment identity."
  type        = string
}
