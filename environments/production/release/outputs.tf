output "region" {
  description = "Region of the shared invocation resources."
  value       = var.region
}

output "root_name" {
  description = "Stable state boundary for shared invocation resources."
  value       = local.root_name
}
