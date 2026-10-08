locals {
  bucket_name_prefix = "${var.management_project_id}-${data.google_project.management.number}"
}

resource "google_storage_bucket" "state" {
  name          = "${local.bucket_name_prefix}-tofu-state"
  location      = var.storage_location
  storage_class = "STANDARD"

  force_destroy               = false
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  soft_delete_policy {
    retention_duration_seconds = 604800
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    # Both conditions must match, preserving at least 50 generations and every
    # generation younger than 90 days.
    condition {
      days_since_noncurrent_time = 90
      num_newer_versions         = 50
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["storage.googleapis.com"]]
}

resource "google_storage_bucket" "backups" {
  name          = "${local.bucket_name_prefix}-backups"
  location      = var.storage_location
  storage_class = "STANDARD"

  force_destroy               = false
  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true

  # A recovery point cannot be removed during its first seven days. Locking is
  # a separate, irreversible operator step after the first clean restore drill.
  retention_policy {
    retention_period = 604800
    is_locked        = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      age = 14
    }
  }

  # Soft delete would retain a second billable copy after lifecycle deletion.
  # The seven-day bucket retention policy is the deliberate protection here.
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.management["storage.googleapis.com"]]
}

