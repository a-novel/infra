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
  description = "Select the shared private project's JSON Keys database identity."
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
