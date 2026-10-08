variable "images" {
  description = "Service images as ghcr.io/a-novel/<path>:<tag>@<digest>, kept current by Renovate."
  type        = map(string)

  validation {
    condition = toset(keys(var.images)) == toset(["grpc", "migrations", "rotatekeys"]) && alltrue([
      for ref in values(var.images) : can(regex("^ghcr\\.io/a-novel/service-json-keys/[^:@]+:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$", ref))
    ])
    error_message = "Pin the grpc, migrations and rotatekeys images by release tag and digest."
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
  description = "Backup repository VM image and the runtime it loads at boot."
  type = object({
    cos_image = string
    runtime = object({
      server_image      = string
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
