variable "service" {
  description = "Service whose database this repository backs up."
  type        = string
}

variable "project_id" {
  description = "Private project hosting the database and the repository."
  type        = string
}

variable "region" {
  description = "Region of the image repositories."
  type        = string
}

variable "placement" {
  description = "Repository VM zone, subnetwork, internal address the database host trusts, and pinned Container-Optimized OS image."
  type = object({
    zone       = string
    subnetwork = string
    ip         = string
    cos_image  = string
  })

  validation {
    condition     = can(regex("^[0-9]{1,3}([.][0-9]{1,3}){3}$", var.placement.ip))
    error_message = "The repository VM needs a fixed internal IPv4 address."
  }
}

variable "machine_type" {
  description = "Repository VM machine type."
  type        = string
  default     = "e2-micro"
}

variable "runtime" {
  description = "Pinned images, TLS client name, and numeric TLS secret versions loaded at boot."
  type = object({
    server_image      = string
    credentials_image = string
    client_name       = string
    ca_version        = string
    identity_version  = string
  })
}

variable "bucket" {
  description = "Management bucket holding this service's backup repository."
  type        = string
}

variable "management_project_number" {
  description = "Management project number; the credentials loader reads TLS secrets there."
  type        = string
}

variable "repository_ids" {
  description = "Service image repository IDs the repository host pulls from."
  type        = map(string)
}

variable "deployer" {
  description = "Service account email that creates the repository VM."
  type        = string
}

variable "notification_channel" {
  description = "Notification channel for backup alerts."
  type        = string
}
