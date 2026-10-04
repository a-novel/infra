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

variable "zone" {
  description = "Shared private jobs/API or public-api request-only contract; null preserves dedicated-service inputs. Protected shared writers remain disabled."
  type        = string
  default     = null

  validation {
    condition     = var.zone == null ? true : contains(["private", "public-api"], var.zone)
    error_message = "Select private or public-api; platforms cannot prepare backend releases."
  }
}

variable "private_project_id" {
  description = "Independently approved database project for public-api; private and dedicated scopes retain their own project."
  type        = string
  default     = null

  validation {
    condition = var.zone == "public-api" ? try(
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.private_project_id)) &&
      var.private_project_id != var.project_id && var.private_project_id != var.management_project_id,
    false) : var.private_project_id == null
    error_message = "Only public-api must independently select its distinct private database project."
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
  validation {
    condition     = var.zone == "public-api" ? try(split("/", var.network.network)[1] == var.private_project_id, false) : true
    error_message = "Public-api must attach to the independently approved private project's network."
  }
}

variable "images" {
  description = "Promoted digests keyed by job role, selected from a separately verified complete image family."
  type        = map(string)
  nullable    = false

  validation {
    condition     = var.zone == "public-api" ? length(var.images) == 0 : toset(keys(var.images)) == toset(keys(local.jobs))
    error_message = "Private/dedicated scope requires its job images; public-api requires an empty map and cannot own jobs."
  }
  validation {
    condition = alltrue([for role, image in var.images : can(regex(
      "^${replace(local.production_repository, ".", "\\.")}/service-${var.service}/jobs/${role}@sha256:[a-f0-9]{64}$", image,
    ))])
    error_message = "Each job must use its exact promoted path and SHA-256 digest in this service project's regional registry."
  }
}

variable "secret_versions" {
  description = "Exact component's enabled numeric secret versions; payloads are never inputs and public JSON Keys excludes the master key."
  type        = map(number)
  nullable    = false

  validation {
    condition     = toset(keys(var.secret_versions)) == local.required_secrets
    error_message = "Supply exactly the selected component's secret versions; no initializer, backup or peer credential is accepted."
  }
  validation {
    condition     = alltrue([for version in values(var.secret_versions) : try(version >= 1 && version == floor(version), false)])
    error_message = "Select positive integer secret versions verified enabled before deployment."
  }
}
