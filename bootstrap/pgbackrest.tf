variable "json_keys_pgbackrest" {
  description = "Opt-in native repository custody for the registered JSON Keys service project. Leave null until separately approved; this does not activate backups."
  type        = object({ workload_project_id = string })
  default     = null

  validation {
    condition = var.json_keys_pgbackrest == null ? true : (
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.json_keys_pgbackrest.workload_project_id)) &&
      var.json_keys_pgbackrest.workload_project_id != var.management_project_id
    )
    error_message = "Use the independently registered JSON Keys project, distinct from management."
  }
}

locals {
  pgbackrest = var.json_keys_pgbackrest == null ? {} : { "json-keys" = var.json_keys_pgbackrest }
  pgbackrest_permissions = var.json_keys_pgbackrest == null ? {} : {
    writer   = ["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.delete"]
    recovery = ["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.restore"]
  }
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

  # Physical dependencies expire as native backup chains, never by object age.
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["storage.googleapis.com"]]
}

resource "google_project_iam_custom_role" "pgbackrest" {
  for_each = local.pgbackrest_permissions

  project     = var.management_project_id
  role_id     = "pgBackRest_json_keys_${each.key}"
  title       = "JSON Keys native backup ${each.key}"
  stage       = "GA"
  permissions = each.value

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_service_account" "pgbackrest_recovery" {
  for_each = local.pgbackrest

  project      = var.management_project_id
  account_id   = "pgbr-${each.key}-recovery"
  display_name = "JSON Keys native backup recovery"
  disabled     = true

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["iam.googleapis.com"]]
}

resource "google_storage_bucket_iam_member" "pgbackrest_writer" {
  for_each = local.pgbackrest

  bucket = google_storage_bucket.pgbackrest[each.key].name
  role   = google_project_iam_custom_role.pgbackrest["writer"].name
  member = "serviceAccount:agora-database@${each.value.workload_project_id}.iam.gserviceaccount.com"
}

resource "google_storage_bucket_iam_member" "pgbackrest_recovery" {
  for_each = local.pgbackrest

  bucket = google_storage_bucket.pgbackrest[each.key].name
  role   = google_project_iam_custom_role.pgbackrest["recovery"].name
  member = "serviceAccount:${google_service_account.pgbackrest_recovery[each.key].email}"
}

output "json_keys_pgbackrest" {
  description = "Optional native repository coordinates, not backup readiness or recovery authorization."
  value = var.json_keys_pgbackrest == null ? null : {
    schema_version     = 1
    service            = "json-keys"
    management_project = var.management_project_id
    workload_project   = var.json_keys_pgbackrest.workload_project_id
    bucket             = google_storage_bucket.pgbackrest["json-keys"].name
    writer             = "agora-database@${var.json_keys_pgbackrest.workload_project_id}.iam.gserviceaccount.com"
    recovery           = google_service_account.pgbackrest_recovery["json-keys"].email
  }

  depends_on = [
    google_storage_bucket_iam_member.pgbackrest_writer,
    google_storage_bucket_iam_member.pgbackrest_recovery,
    google_storage_bucket_iam_member.foundation_admin,
    google_storage_bucket_iam_member.operator_admin,
  ]
}
