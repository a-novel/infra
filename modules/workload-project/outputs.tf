output "project_id" {
  description = "Service-owned project ID."
  value       = google_project.service.project_id
}

output "project_number" {
  description = "Project number for billing and Google-managed service identities."
  value       = google_project.service.number
}
