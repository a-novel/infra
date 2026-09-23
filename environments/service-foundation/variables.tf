variable "state_bucket" {
  description = "Published management state bucket; the protected caller authorizes it before backend initialization."
  type        = string
  nullable    = false

  validation {
    condition     = length(var.state_bucket) <= 63 && can(regex("^${var.management_project_id}-[1-9][0-9]*-tofu-state$", var.state_bucket))
    error_message = "Use the management project's published state bucket."
  }
}

variable "project_id" {
  description = "Existing project dedicated to this production service. Apply workload-project prerequisites first."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Use a valid 6-30 character Google Cloud project ID."
  }
}

variable "service" {
  description = "Application whose reviewed runtime-secret contract this foundation owns."
  type        = string
  nullable    = false

  validation {
    condition     = contains(keys(local.runtime_secrets), var.service)
    error_message = "Select json-keys or authentication; another service needs its own reviewed runtime-secret contract."
  }
}

variable "management_project_id" {
  description = "Distinct surviving project that owns secret containers and the recovery identity."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.management_project_id)) &&
      var.management_project_id != var.project_id
    )
    error_message = "Use a valid management project ID distinct from the service project."
  }
}

variable "region" {
  description = "Region shared by the image repositories and the selected service's Cloud Run deployment."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[1-9][0-9]*$", var.region))
    error_message = "Use a Google Cloud region such as europe-west1."
  }
}

variable "operations_alert_email" {
  description = "Monitored operations inbox; verify channel delivery before activating the service."
  type        = string
  nullable    = false
  sensitive   = true
}
