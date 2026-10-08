variable "service" {
  description = "Application name, such as json-keys."
  type        = string
}

variable "zone" {
  description = "Trust zone of the project: private or public-api."
  type        = string

  validation {
    condition     = contains(["private", "public-api"], var.zone)
    error_message = "Backend services run in the private or public-api zone."
  }
}

variable "project_id" {
  description = "Trust-zone project that runs the service."
  type        = string
}

variable "region" {
  description = "Region of the image repositories and Cloud Run workloads."
  type        = string
}

variable "management_project_id" {
  description = "Project that owns the secret containers."
  type        = string
}

variable "secrets" {
  description = "Secret IDs the runtime identity may read."
  type        = set(string)
}

variable "deployer" {
  description = "Service account email that deploys the workloads."
  type        = string
}

variable "alert_email" {
  description = "Operations inbox for this service's alerts."
  type        = string
  sensitive   = true
}
