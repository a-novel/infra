output "region" {
  description = "Configured region used by mocked root tests."
  value       = var.region
}

output "root_name" {
  description = "Stable root identifier used by repository validation."
  value       = local.root_name
}
