variable "retirement" {
  description = "Prepare the audited empty project for a separately approved removal while preserving its logs until project shutdown."
  type        = bool
  default     = false
  nullable    = false
}

variable "project_id" {
  description = "Globally unique ID for the protected project."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Use a valid 6-30 character Google Cloud project ID."
  }
}

variable "billing_account_id" {
  description = "Billing account shared with the foundation."
  type        = string
  sensitive   = true
}

variable "organization_id" {
  description = "Organization parent when no folder is selected."
  type        = string
  default     = null
}

variable "folder_id" {
  description = "Folder parent within the Shared VPC host's organization."
  type        = string
  default     = null
}

variable "labels" {
  description = "Labels selected by the protected foundation owner."
  type        = map(string)
}

variable "foundation_service_account" {
  description = "Protected shared-foundation identity that maintains the project shell."
  type        = string
}

variable "plan_service_account" {
  description = "Read-only infrastructure assessment identity."
  type        = string
}
