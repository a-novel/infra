variable "database_releases" {
  description = "Reviewed database image and existing numeric credential versions, owned by protected foundation maintenance. Empty only for an uninitialized fleet."
  type = map(object({
    image                   = string
    revision                = string
    password_version        = string
    backup_password_version = string
  }))
  default  = {}
  nullable = false

  validation {
    condition = length(var.database_releases) == 0 || (
      toset(keys(var.database_releases)) == toset(["json-keys", "authentication"]) &&
      alltrue([for service, release in var.database_releases :
        can(regex("^${var.region}-docker[.]pkg[.]dev/${var.workload_project_id}/agora-production/service-${service}/database@sha256:[a-f0-9]{64}$", release.image)) &&
        can(regex("^[a-f0-9]{40}$", release.revision)) &&
        can(regex("^[1-9][0-9]*$", release.password_version)) &&
        can(regex("^[1-9][0-9]*$", release.backup_password_version))
      ])
    )
    error_message = "Supply both database releases with promoted digests, revisions and numeric credential versions."
  }
}
