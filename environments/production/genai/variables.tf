variable "secret_versions" {
  description = "Numeric secret versions the workloads read, by secret name suffix."
  type        = map(number)

  validation {
    condition     = toset(keys(var.secret_versions)) == toset(["app-password", "openai-api-key"])
    error_message = "Pin exactly the app-password and openai-api-key versions."
  }
}

variable "alert_email" {
  description = "Operations inbox for this service's alerts."
  type        = string
  sensitive   = true
}

variable "images" {
  description = "Service images as ghcr.io/a-novel/<path>:<tag>@<digest>, pinned by each release."
  type        = map(string)

  validation {
    condition = toset(keys(var.images)) == toset(["grpc", "migrations", "sweep"]) && alltrue([
      for ref in values(var.images) : can(regex("^ghcr\\.io/a-novel/service-genai/[^:@]+:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$", ref))
    ])
    error_message = "Pin the grpc, migrations and sweep images by release tag and digest."
  }
}

variable "downtime" {
  description = "The planned downtime as JSON, from the DOWNTIME repository variable: components, start and end. Empty without one."
  type        = string
  default     = ""

  validation {
    condition     = var.downtime == "" || can(tolist(jsondecode(var.downtime).components)) && can(jsondecode(var.downtime).start)
    error_message = "The planned downtime must be JSON with components, start and end."
  }
}
