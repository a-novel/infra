variable "native_backups" {
  description = "Per-service native lifecycle on existing stateful hosts. Requires protected startup-only replacement; enrollment does not start backup timers."
  type = map(object({
    repository_ip     = string
    server_image      = string
    credentials_image = string
    client_name       = string
    ca_version        = string
    identity_version  = string
    wal_archiving     = optional(bool, false)
  }))
  default  = {}
  nullable = false

  validation {
    condition     = length(distinct([for runtime in var.native_backups : runtime.client_name])) == length(var.native_backups)
    error_message = "Each service requires its own TLS client identity, even when repositories trust the same issuer."
  }
  validation {
    condition = alltrue([for service, runtime in var.native_backups :
      !var.recovery_mode && try(contains(var.service_release_zones[service], "private"), false) &&
      contains(var.pgbackrest_repository_services, service) &&
      cidrcontains(var.subnet_cidr, runtime.repository_ip)
    ])
    error_message = "Native activation requires a registered private service, its repository networking and an address inside the private subnet; recovery copies cannot activate it."
  }
  validation {
    condition = alltrue([for service, runtime in var.native_backups : alltrue([
      can(regex("^${var.region}-docker[.]pkg[.]dev/${var.workload_project_id}/agora-${service}-private-production/service-${service}/database@sha256:[0-9a-f]{64}$", runtime.server_image)),
      can(regex("^${var.region}-docker[.]pkg[.]dev/${var.workload_project_id}/agora-${service}-private-tooling/host-credentials@sha256:[0-9a-f]{64}$", runtime.credentials_image)),
      can(regex("^[a-z0-9][a-z0-9.-]{0,252}$", runtime.client_name)),
      alltrue([for version in [runtime.ca_version, runtime.identity_version] : can(regex("^[1-9][0-9]{0,19}$", version))]),
    ])])
    error_message = "Native activation requires promoted service-scoped image digests and numeric TLS versions."
  }
}

module "native_backup" {
  source   = "../../../modules/database-runtime"
  for_each = var.native_backups

  service           = each.key
  project_id        = var.workload_project_id
  region            = var.region
  management_number = trimprefix(trimsuffix(var.backup_bucket_name, "-backups"), "${var.management_project_id}-")
  shared_private    = true
  identity_version  = each.value.identity_version
  wal_archiving     = each.value.wal_archiving
  repository = merge(each.value, {
    name = "agora-pgbackrest-${each.key}.${var.database_zone}.c.${var.workload_project_id}.internal"
    ip   = each.value.repository_ip
  })
}
