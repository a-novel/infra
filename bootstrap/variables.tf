variable "management_project_id" {
  description = "Immutable Google Cloud project ID for state and recovery resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.management_project_id))
    error_message = "The management project ID must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "region" {
  description = "Google Cloud region for regional management resources."
  type        = string
  default     = "europe-west1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "The region must be a valid Google Cloud region name."
  }
}

variable "storage_location" {
  description = "Google Cloud multi-region for management state, backups, and deployment receipts."
  type        = string
  default     = "EU"

  validation {
    condition     = var.storage_location == "EU"
    error_message = "Management data must remain in the EU multi-region."
  }
}

variable "operator_principals" {
  description = "Google identities that retain the documented human management-plane and recovery permissions. Use user: or group: IAM member syntax."
  type        = set(string)

  validation {
    condition = (
      length(var.operator_principals) > 0 &&
      alltrue([
        for principal in var.operator_principals :
        can(regex("^(user|group):[^[:space:]@]+@[^[:space:]@]+$", principal))
      ])
    )
    error_message = "Provide at least one operator as user:email or group:email. Service accounts and broad principals are not accepted."
  }
}
