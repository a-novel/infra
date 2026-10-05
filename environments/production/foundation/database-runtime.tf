variable "json_keys_native_backup" {
  description = "JSON Keys native lifecycle on the existing stateful host. Requires protected startup-only host replacement; defaults off and leaves logical backups and native timers unchanged."
  type = object({
    repository_ip     = string
    server_image      = string
    credentials_image = string
    ca_version        = string
    identity_version  = string
    wal_archiving     = optional(bool, false)
  })
  default = null

  validation {
    condition = var.json_keys_native_backup == null ? true : (
      !var.recovery_mode && try(contains(var.service_release_zones["json-keys"], "private"), false) &&
      contains(var.pgbackrest_repository_services, "json-keys") &&
      cidrcontains(var.subnet_cidr, var.json_keys_native_backup.repository_ip)
    )
    error_message = "Native activation requires the registered private JSON Keys service, repository networking and an address inside the private subnet; recovery copies cannot activate it."
  }
  validation {
    condition = var.json_keys_native_backup == null ? true : alltrue([
      can(regex("^${var.region}-docker[.]pkg[.]dev/${var.workload_project_id}/agora-json-keys-private-production/service-json-keys/database@sha256:[0-9a-f]{64}$", var.json_keys_native_backup.server_image)),
      can(regex("^${var.region}-docker[.]pkg[.]dev/${var.workload_project_id}/agora-json-keys-private-tooling/host-credentials@sha256:[0-9a-f]{64}$", var.json_keys_native_backup.credentials_image)),
      alltrue([for version in [var.json_keys_native_backup.ca_version, var.json_keys_native_backup.identity_version] : can(regex("^[1-9][0-9]{0,19}$", version))]),
    ])
    error_message = "Native activation requires promoted service-scoped image digests and numeric TLS versions."
  }
}

module "json_keys_native_backup" {
  source = "../../../modules/database-runtime"
  count  = var.json_keys_native_backup == null ? 0 : 1

  project_id        = var.workload_project_id
  region            = var.region
  management_number = trimprefix(trimsuffix(var.backup_bucket_name, "-backups"), "${var.management_project_id}-")
  shared_private    = true
  identity_version  = var.json_keys_native_backup.identity_version
  wal_archiving     = var.json_keys_native_backup.wal_archiving
  repository = merge(var.json_keys_native_backup, {
    name = "agora-pgbackrest-json-keys.${var.database_zone}.c.${var.workload_project_id}.internal"
    ip   = var.json_keys_native_backup.repository_ip
  })
}
