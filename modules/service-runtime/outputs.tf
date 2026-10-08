output "service_account" {
  description = "Runtime service account email."
  value       = google_service_account.runtime.email
}

output "member" {
  description = "Runtime IAM member, for grants made by the caller."
  value       = google_service_account.runtime.member
}

output "repositories" {
  description = "Image repository URLs by purpose (production, tooling)."
  value = { for purpose, repository in google_artifact_registry_repository.images :
    purpose => "${repository.location}-docker.pkg.dev/${repository.project}/${repository.repository_id}"
  }
}

output "repository_ids" {
  description = "Image repository IDs by purpose, for IAM grants."
  value       = { for purpose, repository in google_artifact_registry_repository.images : purpose => repository.repository_id }
}

output "notification_channel" {
  description = "Operations notification channel name."
  value       = google_monitoring_notification_channel.operations.name
}
