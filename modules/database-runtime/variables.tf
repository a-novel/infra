variable "service" {
  description = "Service owning the database, stanza and TLS secrets."
  type        = string

  validation {
    condition     = contains(["json-keys", "authentication"], var.service)
    error_message = "Select a supported database service."
  }
}

variable "project_id" {
  description = "Project owning the database and repository hosts."
  type        = string
}

variable "region" {
  description = "Artifact Registry region."
  type        = string
}

variable "management_number" {
  description = "Numeric project owning the pinned TLS secrets."
  type        = string
}

variable "shared_private" {
  description = "Select the service's database identity in the shared private project."
  type        = bool
  default     = false
}

variable "repository" {
  description = "Private repository endpoint and exact runtime inputs."
  type = object({
    name              = string
    ip                = string
    server_image      = string
    credentials_image = string
    ca_version        = string
    client_name       = string
  })
}

variable "identity_version" {
  description = "Numeric database TLS identity version."
  type        = string
}

variable "wal_archiving" {
  description = "Enable native WAL archiving when the database starts."
  type        = bool
  default     = false
}

variable "schedules_enabled" {
  description = "Start the native schedules with a healthy database, after backup and isolated restore acceptance."
  type        = bool
  default     = false

  validation {
    condition     = !var.schedules_enabled || var.wal_archiving
    error_message = "Scheduled backups require WAL archiving."
  }
}
