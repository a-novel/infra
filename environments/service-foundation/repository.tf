variable "pgbackrest_repository" {
  description = "Optional JSON Keys repository host, stopped unless guarded bring-up is selected. Runtime installs a disabled service."
  type = object({
    machine_type = optional(string, "e2-micro")
    # Shared projects place the repository without taking ownership of the database.
    placement = optional(object({
      zone       = string
      subnetwork = string
      cos_image  = string
    }))
    runtime = optional(object({
      server_image      = string
      credentials_image = string
      ca_version        = string
      identity_version  = string
    }))
  })
  default = null

  validation {
    condition = var.pgbackrest_repository == null ? true : (
      var.service == "json-keys" && (
        var.zone == null ? var.database != null && var.pgbackrest_repository.placement == null : try(
          var.zone == "private" && var.database == null &&
          var.pgbackrest_repository.runtime == null && var.pgbackrest_repository.machine_type == "e2-micro" &&
          var.pgbackrest_repository.placement.zone == jsondecode(var.database_handoff.document_json).zone &&
          can(regex("^projects/${var.project_id}/regions/${var.region}/subnetworks/[a-z][a-z0-9-]*$", var.pgbackrest_repository.placement.subnetwork)) &&
          can(regex("^projects/cos-cloud/global/images/cos-[0-9]+(-[0-9]+)+$", var.pgbackrest_repository.placement.cos_image)),
          false
        )
      ) && contains(["e2-micro", "e2-small"], var.pgbackrest_repository.machine_type)
    )
    error_message = "The JSON Keys repository requires reviewed placement. Shared private scopes admit only a stopped micro host beside the published database, without database ownership or runtime activation."
  }

  validation {
    condition = try(var.pgbackrest_repository.runtime, null) == null ? true : alltrue([
      can(regex("^${var.region}-docker[.]pkg[.]dev/${var.project_id}/agora-production/service-json-keys/database@sha256:[0-9a-f]{64}$", var.pgbackrest_repository.runtime.server_image)),
      can(regex("^${var.region}-docker[.]pkg[.]dev/${var.project_id}/agora-tooling/host-credentials@sha256:[0-9a-f]{64}$", var.pgbackrest_repository.runtime.credentials_image)),
    ])
    error_message = "Repository runtime images must be approved promoted digests in this service project's application and tooling repositories."
  }

  validation {
    condition = try(var.pgbackrest_repository.runtime, null) == null ? true : alltrue([
      for version in [var.pgbackrest_repository.runtime.ca_version, var.pgbackrest_repository.runtime.identity_version] :
      can(regex("^[1-9][0-9]{0,19}$", version))
    ])
    error_message = "Repository TLS versions must be positive numeric versions, never aliases."
  }
}

locals {
  repository_placement = var.zone == null ? {
    zone       = try(var.database.zone, null)
    subnetwork = try(var.database.subnetwork, null)
    cos_image  = try(var.database.cos_image, null)
  } : try(var.pgbackrest_repository.placement, null)
  pgbackrest_repository = var.pgbackrest_repository == null || local.repository_placement == null ? {} : { host = var.pgbackrest_repository }
  repository_name       = try("agora-pgbackrest-json-keys.${local.repository_placement.zone}.c.${var.project_id}.internal", "")
}

resource "google_service_account" "repository" {
  for_each = local.pgbackrest_repository

  project      = var.project_id
  account_id   = var.zone == null ? "agora-backup-repository" : "agora-pgbr-${var.service}"
  display_name = "Agora ${var.service} native backup repository"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account_iam_member" "repository_attachment" {
  for_each = local.pgbackrest_repository

  service_account_id = google_service_account.repository[each.key].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.foundation_service_account}"
}

resource "google_compute_instance" "repository" {
  for_each = local.pgbackrest_repository

  project                   = var.project_id
  zone                      = local.repository_placement.zone
  name                      = "agora-pgbackrest-${var.service}"
  machine_type              = each.value.machine_type
  desired_status            = var.zone == null && local.native_host_bringup ? "RUNNING" : "TERMINATED"
  allow_stopping_for_update = false
  deletion_protection       = true
  can_ip_forward            = false
  tags                      = ["agora-pgbackrest-${var.service}"]
  labels                    = { component = var.service, role = "backup-repository" }

  boot_disk {
    auto_delete = true
    initialize_params {
      image = local.repository_placement.cos_image
      size  = 20
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = local.repository_placement.subnetwork
  }

  service_account {
    email  = google_service_account.repository[each.key].email
    scopes = ["cloud-platform"]
  }

  metadata = merge({
    block-project-ssh-keys    = "TRUE"
    cos-update-strategy       = "update_disabled"
    disable-legacy-endpoints  = "TRUE"
    enable-guest-attributes   = "FALSE"
    enable-oslogin            = "TRUE"
    google-logging-enabled    = "false"
    google-monitoring-enabled = "false"
    serial-port-enable        = "FALSE"
  }, each.value.runtime == null ? {} : { user-data = local.repository_cloud_config[each.key] })

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    preemptible         = false
    provisioning_model  = "STANDARD"
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = true
    enable_vtpm                 = true
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_service_account_iam_member.repository_attachment]
}

output "pgbackrest_repository" {
  description = "Repository host coordinates; bootstrap separately grants its management-bucket access. This is not backup readiness."
  value = length(local.pgbackrest_repository) == 0 ? null : {
    schema_version  = 1
    project_id      = var.project_id
    service         = var.service
    zone            = local.repository_placement.zone
    instance        = google_compute_instance.repository["host"].name
    service_account = google_service_account.repository["host"].email
  }
}
