# Compute Engine snapshots complement logical dumps: they are fast,
# crash-consistent host recovery points, not a substitute for tested pg_restore.
resource "google_compute_resource_policy" "database_snapshots" {
  project = google_project.workload.project_id
  region  = var.region
  name    = "agora-database-daily-snapshots"

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
      guest_flush = false
      labels      = merge(local.labels, { role = "database-snapshot" })
      # These remain globally scoped snapshots, but storing their data beside
      # the source disk avoids multi-region transfer cost. Logical backups in
      # the management project remain the regional-loss recovery layer.
      storage_locations = [var.region]
    }
  }

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
}

resource "google_compute_disk_resource_policy_attachment" "database_snapshots" {
  project = google_project.workload.project_id
  zone    = var.database_zone
  disk    = google_compute_disk.database.name
  name    = google_compute_resource_policy.database_snapshots.name
}
