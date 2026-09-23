# Crash-consistent snapshots complement, but cannot replace, tested logical backups.
resource "google_compute_resource_policy" "database" {
  for_each = local.database

  project = var.project_id
  region  = var.region
  name    = "agora-${var.service}-daily-snapshots"
  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "02:00"
      }
    }
    retention_policy {
      max_retention_days    = 7
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      guest_flush       = false
      storage_locations = [var.region]
      labels            = { component = var.service, role = "database-snapshot" }
    }
  }
}

resource "google_compute_disk_resource_policy_attachment" "database" {
  for_each = local.database

  project = var.project_id
  zone    = each.value.zone
  disk    = google_compute_disk.database[each.key].name
  name    = google_compute_resource_policy.database[each.key].name
}
