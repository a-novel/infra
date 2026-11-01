variable "service" {
  description = "Application name, such as json-keys."
  type        = string
}

variable "project_id" {
  description = "Workload project that holds the service's repositories."
  type        = string
}

variable "region" {
  description = "Region of the image repositories."
  type        = string
}

variable "database_service_account" {
  description = "Email of the service's database host identity, owned by the foundation root. Null for a service without a database host."
  type        = string
  default     = null
}

variable "alert_email" {
  description = "Operations inbox for this service's alerts."
  type        = string
  sensitive   = true
}
