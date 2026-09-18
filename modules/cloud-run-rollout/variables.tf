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
    condition     = can(regex("^[a-z]([a-z0-9-]{0,54}[a-z0-9])?$", var.name))
    error_message = "Use a lowercase 1-56 character service name, leaving space for the probe job suffix."
  }
}

variable "runtime_service_account" {
  description = "Existing application identity the deploy worker may attach; owned by the service foundation."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]@${var.project_id}\\.iam\\.gserviceaccount\\.com$", var.runtime_service_account)) &&
      !contains([for name in ["infra-release", "rollout-deploy", "rollout-verify", "rollout-probe"] :
        "${name}@${var.project_id}.iam.gserviceaccount.com"
      ], var.runtime_service_account)
    )
    error_message = "Use an application identity in this service project, distinct from release and rollout identities."
  }
}

variable "artifact_bucket" {
  description = "Globally unique name for the private service-project bucket this module creates for rollout artifacts."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.artifact_bucket))
    error_message = "Use a 3-63 character bucket name containing lowercase letters, digits, and hyphens."
  }
}

variable "receipt_bucket" {
  description = "Existing private management receipt bucket with uniform access and the workload-project-owned service prefix."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.receipt_bucket)) &&
      var.receipt_bucket != var.artifact_bucket
    )
    error_message = "Use a valid management receipt bucket distinct from the rollout artifact bucket."
  }
}

variable "notification_channels" {
  description = "Existing operations channels in this service project, using project-ID resource names; delivery must be verified before activation."
  type        = set(string)
  nullable    = false

  validation {
    condition = (
      length(var.notification_channels) > 0 && length(var.notification_channels) <= 16 &&
      alltrue([for channel in var.notification_channels :
        can(regex("^projects/${var.project_id}/notificationChannels/[1-9][0-9]*$", channel))
      ])
    )
    error_message = "Supply 1-16 existing operations channels using projects/<this-project-id>/notificationChannels/<numeric-id>."
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

variable "probe" {
  description = "Foundation-owned network/subnet coordinates, including Shared VPC; routing and firewall access remain foundation prerequisites."
  type = object({
    network    = string
    subnetwork = string
  })
  nullable = false

  validation {
    condition = (
      can(regex("^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/global/networks/[a-z][a-z0-9-]+$", var.probe.network)) &&
      can(regex("^projects/${try(split("/", var.probe.network)[1], "")}/regions/${var.region}/subnetworks/[a-z][a-z0-9-]+$", var.probe.subnetwork))
    )
    error_message = "Use an exact network/subnet pair in one approved host project and target region."
  }
}
