variable "state_bucket" {
  description = "Management state bucket from the protected workload-project release coordinates; no credentials belong in this value."
  type        = string
  nullable    = false

  validation {
    condition     = length(var.state_bucket) <= 63 && can(regex("^${var.management_project_id}-[1-9][0-9]*-tofu-state$", var.state_bucket))
    error_message = "Use the management project's published state bucket."
  }
}

variable "project_id" {
  description = "Service project independently authorized against protected registration before backend initialization."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "Use a valid service project ID."
  }
}

variable "service" {
  description = "Independently approved service identity; never inferred from the downloaded document."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["json-keys", "authentication"], var.service)
    error_message = "Select JSON Keys or Authentication."
  }
}

variable "region" {
  description = "Independently approved region for this service's jobs and database."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[1-9][0-9]*$", var.region))
    error_message = "Use a valid Google Cloud region."
  }
}

variable "management_project_id" {
  description = "Distinct management project that owns the service's existing secret containers."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.management_project_id)) &&
      var.management_project_id != var.project_id
    )
    error_message = "Use a valid management project ID distinct from the service project."
  }
}

variable "network" {
  description = "Approved Shared VPC network/subnet pair; the host foundation supplies subnet IAM and service-specific firewall rules."
  type        = object({ network = string, subnetwork = string })
  nullable    = false

  validation {
    condition = (
      can(regex("^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/global/networks/[a-z][a-z0-9-]+$", var.network.network)) &&
      can(regex("^projects/${try(split("/", var.network.network)[1], "")}/regions/${var.region}/subnetworks/[a-z][a-z0-9-]+$", var.network.subnetwork))
    )
    error_message = "Use an exact network/subnet pair in one approved host project and the selected region."
  }
}

variable "images" {
  description = "Promoted digests keyed by job role, selected from a separately verified complete image family."
  type        = map(string)
  nullable    = false

  validation {
    condition     = toset(keys(var.images)) == toset(keys(local.jobs))
    error_message = "Supply migrations and, only for JSON Keys, rotatekeys; no initializer or peer job is accepted."
  }
  validation {
    condition = alltrue([for role, image in var.images : can(regex(
      "^${var.region}-docker\\.pkg\\.dev/${var.project_id}/agora-production/service-${var.service}/jobs/${role}@sha256:[a-f0-9]{64}$", image,
    ))])
    error_message = "Each job must use its exact promoted path and SHA-256 digest in this service project's regional registry."
  }
}

variable "secret_versions" {
  description = "Enabled numeric versions keyed by postgres-password and, for JSON Keys, app-master-key; payloads are never inputs."
  type        = map(number)
  nullable    = false

  validation {
    condition     = toset(keys(var.secret_versions)) == local.required_secrets
    error_message = "Supply exactly this service's job-secret versions; no initializer, SMTP, backup or peer credential is accepted."
  }
  validation {
    condition     = alltrue([for version in values(var.secret_versions) : try(version >= 1 && version == floor(version), false)])
    error_message = "Select positive integer secret versions verified enabled before deployment."
  }
}
