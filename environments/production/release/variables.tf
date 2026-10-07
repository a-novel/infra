variable "workload_project_id" {
  description = "Private project containing the existing application jobs and internal API."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.workload_project_id))
    error_message = "The workload project ID must be a valid Google Cloud project ID."
  }
}

variable "region" {
  description = "Region containing the existing application jobs and internal API."
  type        = string
  default     = "europe-west1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "The region must be a valid Google Cloud region name."
  }
}

variable "runtime_service_accounts" {
  description = "Existing foundation-owned scheduler identity."
  type        = object({ scheduler_invoker = string })

  validation {
    condition     = var.runtime_service_accounts.scheduler_invoker == "agora-scheduler-invoker@${var.workload_project_id}.iam.gserviceaccount.com"
    error_message = "Rotation must use the exact foundation-owned scheduler identity."
  }
}

variable "cloud_run_invocation_tags" {
  description = "Permanent foundation-owned tag values for private API and job invocation."
  type = object({
    values = object({
      internal  = string
      release   = string
      scheduled = string
    })
  })

  validation {
    condition = alltrue([
      for value in values(var.cloud_run_invocation_tags.values) :
      can(regex("^tagValues/[0-9]+$", value))
    ])
    error_message = "Invocation tags must be permanent tagValues/<number> IDs."
  }
}
