variable "runtime" {
  description = "Selected service-foundation runtime output; the caller authorizes these coordinates before applying."
  type = object({
    schema_version  = number
    project_id      = string
    service         = string
    region          = string
    service_account = string
  })
  nullable = false

  validation {
    condition     = var.runtime.schema_version == 1 && contains(["json-keys", "authentication"], var.runtime.service)
    error_message = "Use a version-1 JSON Keys or Authentication runtime contract."
  }
  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.runtime.project_id)) &&
      can(regex("^[a-z]+-[a-z]+[1-9][0-9]*$", var.runtime.region))
    )
    error_message = "Use a valid service project ID and Google Cloud region."
  }
  validation {
    condition     = var.runtime.service_account == "agora-${var.runtime.service}@${var.runtime.project_id}.iam.gserviceaccount.com"
    error_message = "Use this service's application identity in its own project."
  }
}

variable "management_project_id" {
  description = "Distinct management project that owns the service's existing secret containers."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.management_project_id)) &&
      var.management_project_id != var.runtime.project_id
    )
    error_message = "Use a valid management project ID distinct from the service project."
  }
}

variable "database_private_ip" {
  description = "Selected service database's approved RFC1918 address; routing and database ownership stay with foundation."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(cidrnetmask("${var.database_private_ip}/32")) &&
      can(regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)", var.database_private_ip))
    )
    error_message = "Use the selected service's private IPv4 database address."
  }
}

variable "network" {
  description = "Approved Shared VPC network/subnet pair; the host foundation supplies subnet IAM and service-specific firewall rules."
  type        = object({ network = string, subnetwork = string })
  nullable    = false

  validation {
    condition = (
      can(regex("^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/global/networks/[a-z][a-z0-9-]+$", var.network.network)) &&
      can(regex("^projects/${try(split("/", var.network.network)[1], "")}/regions/${var.runtime.region}/subnetworks/[a-z][a-z0-9-]+$", var.network.subnetwork))
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
      "^${var.runtime.region}-docker\\.pkg\\.dev/${var.runtime.project_id}/agora-production/service-${var.runtime.service}/jobs/${role}@sha256:[a-f0-9]{64}$", image,
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
