variable "secret_versions" {
  description = "Numeric secret versions the workloads read, by secret name suffix."
  type        = map(number)

  validation {
    condition     = toset(keys(var.secret_versions)) == toset(["postgres-password", "openai-api-key"])
    error_message = "Pin exactly the postgres-password and openai-api-key versions."
  }
}

variable "alert_email" {
  description = "Operations inbox for this service's alerts."
  type        = string
  sensitive   = true
}
