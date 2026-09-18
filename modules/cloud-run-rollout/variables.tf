variable "project_id" {
  description = "Project dedicated to this service and environment; pipeline, target, and execution identities stay here."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Use a valid 6-30 character Google Cloud project ID."
  }
}

variable "region" {
  description = "Region shared by the delivery pipeline, target, and Cloud Run service."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[1-9][0-9]*$", var.region))
    error_message = "Use a Google Cloud region name such as europe-west1."
  }
}

variable "name" {
  description = "Exact Cloud Run service name, also used for its sole pipeline and target."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.name))
    error_message = "Use a valid lowercase 1-63 character Cloud Run service name."
  }
}

variable "execution_service_accounts" {
  description = "Pre-provisioned, distinct same-project accounts for render/deploy and verification; this module grants no IAM."
  type = object({
    deploy = string
    verify = string
  })
  nullable = false

  validation {
    condition = (
      var.execution_service_accounts.deploy != var.execution_service_accounts.verify &&
      alltrue([for account in values(var.execution_service_accounts) :
        can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@${var.project_id}\\.iam\\.gserviceaccount\\.com$", account))
      ])
    )
    error_message = "Use distinct deploy and verify service accounts from the selected service project."
  }
}

variable "artifact_bucket" {
  description = "Existing private artifact bucket name (no gs://); access must be scoped to this module's service prefix."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.artifact_bucket))
    error_message = "Use a 3-63 character bucket name containing lowercase letters, digits, and hyphens."
  }
}

variable "verification_image" {
  description = "Reviewed verifier with its own entrypoint, promoted to this project's regional registry and pinned by digest. See README for its required contract."
  type        = string
  nullable    = false

  validation {
    condition = can(regex(
      "^${var.region}-docker\\.pkg\\.dev/${var.project_id}/[a-z0-9-]+/[a-z0-9/_-]+@sha256:[a-f0-9]{64}$",
      var.verification_image,
    ))
    error_message = "Pin the reviewed verifier by SHA-256 digest in the selected project's regional Artifact Registry."
  }
}
