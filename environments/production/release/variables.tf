variable "management_project_id" {
  description = "Stable Google Cloud project ID containing the logical backup bucket and secret containers."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.management_project_id))
    error_message = "The management project ID must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "workload_project_id" {
  description = "Immutable Google Cloud project ID for the production workload."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.workload_project_id))
    error_message = "The workload project ID must be a valid 6-30 character Google Cloud project ID."
  }
}

variable "region" {
  description = "Google Cloud region for production resources."
  type        = string
  default     = "europe-west1"

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]+$", var.region))
    error_message = "The region must be a valid Google Cloud region name."
  }
}

variable "backup_bucket_name" {
  description = "Bootstrap-owned EU bucket that stores committed logical PostgreSQL recovery points."
  type        = string

  validation {
    condition     = can(regex("^${var.management_project_id}-[0-9]+-backups$", var.backup_bucket_name))
    error_message = "The backup bucket must be the bootstrap output for the configured management project."
  }
}

variable "database_private_ip" {
  description = "Preserved private address of the stateful PostgreSQL host."
  type        = string

  validation {
    condition = (
      can(cidrhost("${var.database_private_ip}/32", 0)) &&
      can(regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)", var.database_private_ip))
    )
    error_message = "The database host must be a valid private IPv4 address."
  }
}

variable "network_id" {
  description = "Full resource ID of the foundation-owned production VPC."
  type        = string

  validation {
    condition     = can(regex("^projects/${var.workload_project_id}/global/networks/agora-production$", var.network_id))
    error_message = "The network ID must identify the foundation-owned Agora production VPC."
  }
}

variable "subnet_id" {
  description = "Full resource ID of the foundation-owned regional production subnet."
  type        = string

  validation {
    condition     = can(regex("^projects/${var.workload_project_id}/regions/${var.region}/subnetworks/agora-production-${var.region}$", var.subnet_id))
    error_message = "The subnet ID must identify the foundation-owned Agora production subnet."
  }
}

variable "runtime_service_accounts" {
  description = "Foundation-owned keyless identities used by application, backup, restore, and scheduler workloads."
  type = object({
    authentication    = string
    backup            = string
    json_keys         = string
    restore           = string
    scheduler_invoker = string
  })

  validation {
    condition = (
      var.runtime_service_accounts.authentication == "agora-authentication@${var.workload_project_id}.iam.gserviceaccount.com" &&
      var.runtime_service_accounts.backup == "agora-backup@${var.workload_project_id}.iam.gserviceaccount.com" &&
      var.runtime_service_accounts.json_keys == "agora-json-keys@${var.workload_project_id}.iam.gserviceaccount.com" &&
      var.runtime_service_accounts.restore == "agora-restore@${var.workload_project_id}.iam.gserviceaccount.com" &&
      var.runtime_service_accounts.scheduler_invoker == "agora-scheduler-invoker@${var.workload_project_id}.iam.gserviceaccount.com"
    )
    error_message = "Runtime identities must be the five exact foundation-owned service accounts."
  }
}

variable "database_releases" {
  description = "Enabled database release images and exact read-only backup credential versions. Keep empty until both databases are released."
  type = map(object({
    image                   = string
    backup_password_version = number
  }))
  default = {}

  validation {
    condition = (
      length(var.database_releases) == 0 ||
      toset(keys(var.database_releases)) == toset(["authentication", "json_keys"])
    )
    error_message = "Database recovery is enabled for both Authentication and JSON Keys as one release unit, or for neither."
  }

  validation {
    condition = alltrue([
      for release in values(var.database_releases) :
      release.backup_password_version >= 1 &&
      floor(release.backup_password_version) == release.backup_password_version
    ])
    error_message = "Every backup password version must be a positive numeric Secret Manager version."
  }
}

variable "application_release" {
  description = "Optional atomic JSON Keys and Authentication runtime release. Values contain promoted image digests, exact secret versions, and non-secret mail/bootstrap configuration."
  type = object({
    authentication = object({
      images = object({
        init       = string
        migrations = string
        rest       = string
      })
      secrets = object({
        postgres_dsn_version         = number
        smtp_password_version        = number
        super_admin_password_version = number
      })
      smtp = object({
        address       = string
        sender_domain = string
        sender_email  = string
        sender_name   = string
      })
      super_admin_email = string
    })
    json_keys = object({
      images = object({
        grpc        = string
        migrations  = string
        rotate_keys = string
      })
      secrets = object({
        app_master_key_version = number
        postgres_dsn_version   = number
      })
    })
  })
  default  = null
  nullable = true

  validation {
    condition = var.application_release == null ? true : alltrue([
      for version in [
        var.application_release.authentication.secrets.postgres_dsn_version,
        var.application_release.authentication.secrets.smtp_password_version,
        var.application_release.authentication.secrets.super_admin_password_version,
        var.application_release.json_keys.secrets.app_master_key_version,
        var.application_release.json_keys.secrets.postgres_dsn_version,
      ] : version >= 1 && floor(version) == version
    ])
    error_message = "Every application secret reference must be a positive numeric Secret Manager version."
  }

  validation {
    condition = var.application_release == null ? true : (
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.application_release.authentication.super_admin_email)) &&
      can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.application_release.authentication.smtp.sender_email))
    )
    error_message = "Authentication bootstrap and SMTP sender values must be valid email addresses."
  }

  validation {
    condition = var.application_release == null ? true : (
      can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?:587$", lower(var.application_release.authentication.smtp.address))) &&
      lower(split(":", var.application_release.authentication.smtp.address)[0]) == lower(var.application_release.authentication.smtp.sender_domain) &&
      length(trimspace(var.application_release.authentication.smtp.sender_name)) >= 1 &&
      length(var.application_release.authentication.smtp.sender_name) <= 100
    )
    error_message = "SMTP must use a DNS host on port 587, repeat that host as sender_domain, and provide a 1-100 character sender name."
  }
}

variable "backup_uploader_image" {
  description = "Small public curl image used only for create-only uploads and read-only recovery monitoring."
  type        = string
  # renovate: datasource=docker depName=alpine/curl versioning=semver
  default = "docker.io/alpine/curl:8.21.0@sha256:1a4d725751c5bd50297ee243db5d4df8ac5aabdf7030dd40dcec3bc3fdaa1cfa"

  validation {
    condition     = can(regex("^docker\\.io/alpine/curl:(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)@sha256:[a-f0-9]{64}$", var.backup_uploader_image))
    error_message = "The curl image must use a complete stable SemVer tag and immutable sha256 digest."
  }
}
