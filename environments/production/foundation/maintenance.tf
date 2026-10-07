resource "google_project_iam_member" "database_maintenance_iap" {
  for_each = { for service, config in var.native_backups : service => config if config.wal_archiving }

  project = google_project.workload.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"

  condition {
    title       = "NativeBackupMaintenanceSSH-${each.key}"
    description = "Fresh backup verification on the existing database host before protected maintenance."
    expression  = "destination.port == 22 && destination.ip == '${one(data.google_compute_instance.database[replace(each.key, "-", "_")].network_interface).network_ip}'"
  }
}
