variable "images" {
  description = "Service images as ghcr.io/a-novel/<path>:<tag>@<digest>, kept current by Renovate."
  type        = map(string)

  validation {
    condition = toset(keys(var.images)) == toset(["database", "grpc", "migrations", "rotatekeys"]) && alltrue([
      for ref in values(var.images) : can(regex("^ghcr\\.io/a-novel/service-json-keys/[^:@]+:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$", ref))
    ])
    error_message = "Pin the database, grpc, migrations and rotatekeys images by release tag and digest."
  }
}

variable "secret_versions" {
  description = "Numeric secret versions the workloads read, by secret name suffix."
  type        = map(number)

  validation {
    condition     = toset(keys(var.secret_versions)) == toset(["postgres-password", "app-master-key"])
    error_message = "Pin exactly the postgres-password and app-master-key versions."
  }
}

variable "backup_repository" {
  description = "Backup repository VM image and the TLS runtime it loads at boot; the server runs the database image."
  type = object({
    cos_image = string
    runtime = object({
      credentials_image = string
      client_name       = string
      ca_version        = string
      identity_version  = string
    })
  })
}

variable "alert_email" {
  description = "Operations inbox for this service's alerts."
  type        = string
  sensitive   = true
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
