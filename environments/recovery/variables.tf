variable "recovery" {
  description = "Disabled by default. Private, independently approved disposable host inputs; never infer authorization from this object."
  type = object({
    service              = optional(string, "json-keys")
    project              = string
    source_project       = string
    protected_projects   = set(string)
    management_project   = string
    management_number    = string
    region               = string
    zone                 = string
    cos_image            = string
    restore_image        = string
    disk_gib             = number
    system_id            = string
    set                  = string
    repository_time      = optional(string, "")
    verify_sql           = optional(bool, false)
    expected_data_sha256 = optional(string, "")
  })
  default = null

  validation {
    condition = var.recovery == null ? true : alltrue([
      contains(["json-keys", "authentication"], var.recovery.service),
      can(regex("^a-novel-recovery-[a-z0-9-]{1,13}[a-z0-9]$", var.recovery.project)),
      !contains(var.recovery.protected_projects, var.recovery.project),
      contains(var.recovery.protected_projects, var.recovery.source_project),
      contains(var.recovery.protected_projects, var.recovery.management_project),
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.recovery.source_project)),
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.recovery.management_project)),
      can(regex("^[1-9][0-9]{5,19}$", var.recovery.management_number)),
    ])
    error_message = "Select a fresh disposable project outside the complete protected registration; include source and management in that registration."
  }
  validation {
    condition = var.recovery == null ? true : alltrue([
      var.recovery.region == "europe-west1",
      contains(["europe-west1-b", "europe-west1-c", "europe-west1-d"], var.recovery.zone),
      can(regex("^projects/cos-cloud/global/images/cos-[0-9]+-[0-9]+-[0-9]+-[0-9]+$", var.recovery.cos_image)),
      can(regex("^europe-west1-docker[.]pkg[.]dev/${var.recovery.project}/agora-tooling/native-restore@sha256:[a-f0-9]{64}$", var.recovery.restore_image)),
      var.recovery.disk_gib >= 10 && var.recovery.disk_gib <= 100 && floor(var.recovery.disk_gib) == var.recovery.disk_gib,
    ])
    error_message = "Use a reviewed COS image, provenanced recovery-project native-restore digest and a sized 10–100 GiB disk in europe-west1."
  }
  validation {
    condition = var.recovery == null ? true : alltrue([
      can(regex("^[1-9][0-9]{0,19}$", var.recovery.system_id)),
      can(regex("^[0-9]{8}-[0-9]{6}F(_[0-9]{8}-[0-9]{6}D)?$", var.recovery.set)),
      var.recovery.repository_time == "" || can(timecmp(var.recovery.repository_time, "2000-01-01T00:00:00Z")),
      var.recovery.expected_data_sha256 == "" || (var.recovery.verify_sql && can(regex("^[a-f0-9]{64}$", var.recovery.expected_data_sha256))),
    ])
    error_message = "Select the independently evidenced database ID and exact backup set/cutoff; a data fingerprint requires verify_sql and a lowercase SHA-256 expectation."
  }
}

locals {
  hosts = var.recovery == null ? {} : { selected = var.recovery }
  requests = { for key, host in local.hosts : key => {
    service              = host.service
    source_project       = host.source_project
    project              = host.project
    management_project   = host.management_project
    management_number    = host.management_number
    system_id            = host.system_id
    major                = 18
    set                  = host.set
    repository_time      = host.repository_time
    verify_sql           = host.verify_sql
    expected_data_sha256 = host.expected_data_sha256
  } }
}
