variable "images" {
  description = "Service images as ghcr.io/a-novel/<path>:<tag>@<digest>, kept current by Renovate."
  type        = map(string)

  validation {
    condition = toset(keys(var.images)) == toset(["migrations", "rest"]) && alltrue([
      for ref in values(var.images) : can(regex("^ghcr\\.io/a-novel/service-authentication/[^:@]+:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$", ref))
    ])
    error_message = "Pin the migrations and rest images by release tag and digest."
  }
}

variable "secret_versions" {
  description = "Numeric secret versions the workloads read, by secret name suffix."
  type        = map(number)

  validation {
    condition = (
      contains(keys(var.secret_versions), "postgres-password") &&
      contains(keys(var.secret_versions), "smtp-sender-password") &&
      (var.waitlist_url == null) != contains(keys(var.secret_versions), "waitlist-secret")
    )
    error_message = "Pin postgres-password and smtp-sender-password, plus waitlist-secret exactly when waitlist_url is set."
  }
}

variable "smtp" {
  description = "Hosted SMTP relay settings; the password is the smtp-sender-password secret."
  type = object({
    host              = string
    username          = string
    sender_email      = string
    sender_name       = string
    platform_auth_url = string
  })
}

variable "waitlist_url" {
  description = "Invitation-list endpoint; null disables the waitlist."
  type        = string
  default     = null
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
