locals {
  permissions = {
    writer   = ["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.delete"]
    recovery = ["storage.objects.create", "storage.objects.get", "storage.objects.list", "storage.objects.restore"]
  }
}

resource "google_storage_bucket" "trial" {
  for_each = toset([var.service, "peer"])

  name                        = "${var.project_id}-${each.key}"
  project                     = var.project_id
  location                    = "EUROPE-WEST1"
  storage_class               = "STANDARD"
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = { purpose = "gcs-storage-proof", service = each.key }

  versioning {
    enabled = true
  }
  retention_policy {
    retention_period = var.retention_seconds
    is_locked        = false
  }
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
}

resource "google_service_account" "trial" {
  for_each = local.permissions

  project      = var.project_id
  account_id   = "gcs-proof-${each.key}"
  display_name = "Storage trial ${each.key}"
}

resource "google_project_iam_custom_role" "trial" {
  for_each = local.permissions

  project     = var.project_id
  role_id     = "gcsProof_${each.key}"
  title       = "Storage trial ${each.key}"
  permissions = each.value
}

resource "google_storage_bucket_iam_member" "trial" {
  for_each = local.permissions

  bucket = google_storage_bucket.trial[var.service].name
  role   = google_project_iam_custom_role.trial[each.key].name
  member = "serviceAccount:${google_service_account.trial[each.key].email}"
}
