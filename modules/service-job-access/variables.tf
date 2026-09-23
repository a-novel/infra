variable "foundation_service_account" {
  description = "Approved shared-foundation executor that attaches the exact scheduling identity during provisioning."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^infra-foundation@[a-z][a-z0-9-]{4,28}[a-z0-9]\\.iam\\.gserviceaccount\\.com$", var.foundation_service_account))
    error_message = "Use the protected infra-foundation service account from the approved management project."
  }
}

variable "runtime" {
  description = "Selected service-foundation runtime output; protected foundation authorizes these coordinates and the existing jobs."
  type = object({
    schema_version        = number
    project_id            = string
    service               = string
    region                = string
    service_account       = string
    notification_channels = set(string)
  })
  nullable = false

  validation {
    condition     = var.runtime.schema_version == 1 && contains(["json-keys", "authentication"], var.runtime.service)
    error_message = "Use a version-1 JSON Keys or Authentication runtime contract."
  }
  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.runtime.project_id)) &&
      can(regex("^[a-z]+-[a-z]+[1-9][0-9]*$", var.runtime.region))
    )
    error_message = "Use a valid service project ID and Google Cloud region."
  }
  validation {
    condition     = var.runtime.service_account == "agora-${var.runtime.service}@${var.runtime.project_id}.iam.gserviceaccount.com"
    error_message = "Attach only this service's application identity in its own project."
  }
  validation {
    condition = (
      length(var.runtime.notification_channels) >= 1 && length(var.runtime.notification_channels) <= 16 &&
      alltrue([for channel in var.runtime.notification_channels :
        can(regex("^projects/${var.runtime.project_id}/notificationChannels/[1-9][0-9]*$", channel))
      ])
    )
    error_message = "Supply one to sixteen notification channels from this service project."
  }
}
