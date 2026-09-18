output "project_id" {
  description = "Service-owned project ID."
  value       = google_project.service.project_id
}

output "project_number" {
  description = "Project number for billing and Google-managed service identities."
  value       = google_project.service.number
}

output "release" {
  description = "Versioned release identity and storage coordinates for publication without sharing foundation state."
  value = {
    schema_version             = 1
    service_account            = google_service_account.release.email
    workload_identity_provider = google_iam_workload_identity_pool_provider.release.name
    environment                = local.release_environment
    state                      = local.release_storage.state
    receipts                   = local.release_storage.receipts
  }
}
