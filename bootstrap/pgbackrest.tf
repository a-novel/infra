variable "native_backups" {
  description = "Per-service native repository custody in the private project. Enrollment does not activate backups."
  type = map(object({
    workload_project_id = string
    zone                = string
    tls_credentials     = optional(bool, false)
    noncurrent_cleanup  = optional(bool, false)
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([for service, config in var.native_backups :
      contains(["json-keys", "authentication"], service) &&
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", config.workload_project_id)) &&
      config.workload_project_id != var.management_project_id
    ])
    error_message = "Select a supported service and its registered database project, distinct from management."
  }

  validation {
    condition     = alltrue([for config in var.native_backups : config.zone == "private"])
    error_message = "Native backup custody belongs only to the private zone."
  }
}

locals {
  pgbackrest = var.native_backups
  pgbackrest_permissions = {
    writer   = ["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.delete"]
    recovery = ["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.restore"]
  }
  pgbackrest_roles = merge([for service in keys(var.native_backups) : {
    for purpose, permissions in local.pgbackrest_permissions : "${service}:${purpose}" => {
      service = service, purpose = purpose, permissions = permissions
    }
  }]...)
}

resource "google_storage_bucket" "pgbackrest" {
  for_each = local.pgbackrest

  project                     = var.management_project_id
  name                        = "${local.bucket_name_prefix}-pgbr-${each.key}"
  location                    = var.storage_location
  storage_class               = "STANDARD"
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = { service = each.key, purpose = "pgbackrest" }

  versioning {
    enabled = true
  }
  retention_policy {
    retention_period = 604800
    is_locked        = false
  }
  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  # pgBackRest owns live chains; GCS disposes only generations no longer current.
  dynamic "lifecycle_rule" {
    for_each = each.value.noncurrent_cleanup ? [true] : []
    content {
      action { type = "Delete" }
      condition {
        with_state                 = "ARCHIVED"
        days_since_noncurrent_time = 7
        send_age_if_zero           = false
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["storage.googleapis.com"]]
}

resource "google_project_iam_custom_role" "pgbackrest" {
  for_each = local.pgbackrest_roles

  project     = var.management_project_id
  role_id     = "pgBackRest_${replace(each.value.service, "-", "_")}_${each.value.purpose}"
  title       = "${each.value.service} native backup ${each.value.purpose}"
  stage       = "GA"
  permissions = each.value.permissions

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_service_account" "pgbackrest_recovery" {
  for_each = local.pgbackrest

  project      = var.management_project_id
  account_id   = "pgbr-${each.key}-recovery"
  display_name = "${each.key} native backup recovery"
  disabled     = true

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_storage_bucket_iam_member" "pgbackrest_writer" {
  for_each = local.pgbackrest

  bucket = google_storage_bucket.pgbackrest[each.key].name
  role   = google_project_iam_custom_role.pgbackrest["${each.key}:writer"].name
  member = "serviceAccount:agora-pgbr-${each.key}@${each.value.workload_project_id}.iam.gserviceaccount.com"
}

resource "google_storage_bucket_iam_member" "pgbackrest_recovery" {
  for_each = local.pgbackrest

  bucket = google_storage_bucket.pgbackrest[each.key].name
  role   = google_project_iam_custom_role.pgbackrest["${each.key}:recovery"].name
  member = "serviceAccount:${google_service_account.pgbackrest_recovery[each.key].email}"
}

output "native_backups" {
  description = "Optional native repository coordinates, not backup readiness or recovery authorization."
  value = { for service, config in var.native_backups : service => {
    schema_version     = 1
    service            = service
    management_project = var.management_project_id
    workload_project   = config.workload_project_id
    bucket             = google_storage_bucket.pgbackrest[service].name
    writer             = "agora-pgbr-${service}@${config.workload_project_id}.iam.gserviceaccount.com"
    recovery           = google_service_account.pgbackrest_recovery[service].email
  } }

  depends_on = [
    google_storage_bucket_iam_member.pgbackrest_writer,
    google_storage_bucket_iam_member.pgbackrest_recovery,
    google_storage_bucket_iam_member.foundation_admin,
    google_storage_bucket_iam_member.operator_admin,
  ]
}
