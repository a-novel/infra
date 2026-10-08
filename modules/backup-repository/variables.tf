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
  description = "Repository VM zone, subnetwork, and pinned Container-Optimized OS image."
  type = object({
    zone       = string
    subnetwork = string
    cos_image  = string
  })
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

variable "database" {
  description = "Database host group, zone, and service account, all owned by the foundation root."
  type = object({
    group           = string
    zone            = string
    service_account = string
  })
}

variable "repository_ids" {
  description = "Service image repository IDs the repository and database hosts pull from."
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
