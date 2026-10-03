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
  value       = module.release.release
}
