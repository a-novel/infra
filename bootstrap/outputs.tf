output "management_project_number" {
  description = "Immutable numeric project identifier used in Workload Identity Federation principals."
  value       = data.google_project.management.number
}

output "automation_service_accounts" {
  description = "Keyless CI service-account emails, keyed by trust boundary."
  value       = { for name, account in google_service_account.automation : name => account.email }
}

output "workload_identity_providers" {
  description = "Workload Identity Federation provider names for GitHub Actions. The setup runbook copies them into the repository's variables."
  value       = { for name, provider in google_iam_workload_identity_pool_provider.github : name => provider.name }
}
