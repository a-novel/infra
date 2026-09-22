output "runtime" {
  description = "Versioned non-payload coordinates for release and rollout callers; publish these without sharing state."
  value = {
    schema_version  = 1
    project_id      = var.project_id
    service         = var.service
    region          = var.region
    service_account = google_service_account.runtime.email
    # Monitoring accepts project numbers too; the rollout contract uses project IDs.
    notification_channels = toset(["projects/${var.project_id}/notificationChannels/${basename(google_monitoring_notification_channel.operations.name)}"])
    repositories = { for name, repository in google_artifact_registry_repository.images : name =>
      "${repository.location}-docker.pkg.dev/${repository.project}/${repository.repository_id}"
    }
  }

  depends_on = [google_secret_manager_secret_iam_member.runtime, google_artifact_registry_repository_iam_member.release]
}
