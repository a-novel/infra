output "project_id" {
  description = "Service-owned project ID."
  value       = module.project.project_id
}

output "project_number" {
  description = "Project number for billing and Google-managed service identities."
  value       = module.project.project_number
}

output "service_agents" {
  description = "Google-managed IAM members after their project service-agent roles are established."
  value       = module.project.service_agents
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
