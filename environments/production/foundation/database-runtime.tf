variable "native_backups" {
  description = "Native backups of each service's database host: the TLS client name and secret versions the host loads, and whether WAL archiving and the backup timers run."
  type = map(object({
    client_name       = string
    ca_version        = string
    identity_version  = string
    wal_archiving     = optional(bool, false)
    schedules_enabled = optional(bool, false)
  }))
  default  = {}
  nullable = false

  validation {
    condition     = length(distinct([for runtime in var.native_backups : runtime.client_name])) == length(var.native_backups)
    error_message = "Each service requires its own TLS client identity, even when repositories trust the same issuer."
  }
  validation {
    condition = alltrue([for service, runtime in var.native_backups :
      try(contains(var.service_release_zones[service], "private"), false) &&
      contains(var.pgbackrest_repository_services, service)
    ])
    error_message = "Native backups need a private service with a backup repository."
  }
  validation {
    condition = alltrue([for service, runtime in var.native_backups : alltrue([
      can(regex("^[a-z0-9][a-z0-9.-]{0,252}$", runtime.client_name)),
      alltrue([for version in [runtime.ca_version, runtime.identity_version] : can(regex("^[1-9][0-9]{0,19}$", version))]),
    ])])
    error_message = "Native backups need a valid TLS client name and numeric TLS secret versions."
  }
}

variable "host_credentials_image" {
  description = "The host-credentials tool, as publish-rollout-verifier.yaml published it: ghcr.io/a-novel/infra/host-credentials:<tag>@<digest>. Deploy verifies and copies it."
  type        = string

  validation {
    condition     = can(regex("^ghcr[.]io/a-novel/infra/host-credentials:[^@]+@sha256:[0-9a-f]{64}$", var.host_credentials_image))
    error_message = "Pin host-credentials by the tag and digest of its publication run."
  }
}

locals {
  host_credentials = regex("^ghcr[.]io/a-novel/infra/host-credentials:(?P<tag>[^@]+)@(?P<digest>sha256:[0-9a-f]{64})$", var.host_credentials_image)
  # Each service's hosts pull the tool, by digest, from that service's private tooling repository.
  host_credentials_repositories = { for service in var.pgbackrest_repository_services : service => "${var.region}-docker.pkg.dev/${var.workload_project_id}/agora-${service}-private-tooling/host-credentials" }
  host_credentials_image        = { for service, repository in local.host_credentials_repositories : service => "${repository}@${local.host_credentials.digest}" }
}

module "native_backup" {
  source   = "../../../modules/database-runtime"
  for_each = var.native_backups

  service           = each.key
  project_id        = var.workload_project_id
  region            = var.region
  management_number = data.google_project.management.number
  identity_version  = each.value.identity_version
  wal_archiving     = each.value.wal_archiving
  schedules_enabled = each.value.schedules_enabled
  repository = merge(each.value, {
    name              = "agora-pgbackrest-${each.key}.${var.database_zone}.c.${var.workload_project_id}.internal"
    ip                = google_compute_address.pgbackrest_repository[each.key].address
    server_image      = local.database_image[each.key]
    credentials_image = local.host_credentials_image[each.key]
  })
}
