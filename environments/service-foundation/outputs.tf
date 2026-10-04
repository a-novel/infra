locals {
  runtime = merge({
    schema_version        = local.coordinates_version
    project_id            = var.project_id
    service               = var.service
    region                = var.region
    service_account       = google_service_account.runtime.email
    notification_channels = toset(["projects/${var.project_id}/notificationChannels/${basename(google_monitoring_notification_channel.operations.name)}"])
    repositories = { for name, repository in google_artifact_registry_repository.images : name =>
      "${repository.location}-docker.pkg.dev/${repository.project}/${repository.repository_id}"
    }
  }, var.zone == null ? {} : { zone = var.zone })
}

output "runtime" {
  description = "Versioned non-payload coordinates for release callers; publish these without sharing state."
  value       = local.runtime
  depends_on = [
    google_secret_manager_secret_iam_member.runtime,
    google_secret_manager_secret_iam_member.foundation_job_metadata,
    google_artifact_registry_repository_iam_member.release,
    google_service_account_iam_member.foundation_runtime,
    google_cloud_run_v2_service_iam_member.json_keys_invoker,
  ]
}
