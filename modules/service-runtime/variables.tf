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

variable "database_service_account" {
  description = "Email of the service's database host identity, owned by the foundation root. Null for a service without a database host."
  type        = string
  default     = null
}

variable "workloads" {
  description = "Workloads that run apart from the main server, by role: each gets its own identity, which reads only the secret IDs listed."
  type = map(object({
    secrets = optional(set(string), [])
  }))
  default = {}

  validation {
    condition     = alltrue([for role in keys(var.workloads) : length("agora-${var.service}-${role}") <= 30])
    error_message = "Each workload's account ID, agora-<service>-<role>, must fit 30 characters."
  }
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
