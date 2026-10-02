output "project_id" {
  description = "Protected project ID, available after its APIs are enabled."
  value       = google_project.service.project_id
  depends_on  = [google_project_service.api]
}

output "project_number" {
  description = "Project number for billing and Google-managed service identities."
  value       = google_project.service.number
}

output "service_agents" {
  description = "Google-managed IAM members after their project service-agent roles are established."
  value       = { for service, binding in google_project_iam_member.service_agent : service => binding.member }
}
