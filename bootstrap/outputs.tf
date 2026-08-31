output "region" {
  description = "Configured region used by mocked root tests."
  value       = var.region
}

output "root_name" {
  description = "Stable root identifier used by repository validation."
  value       = local.root_name
}

output "management_project_number" {
  description = "Immutable numeric project identifier used in Workload Identity Federation principals."
  value       = data.google_project.management.number
}

output "state_bucket_name" {
  description = "Versioned GCS bucket containing OpenTofu state and lock objects."
  value       = google_storage_bucket.state.name
}

output "backup_bucket_name" {
  description = "Durable GCS bucket reserved for workload database backups."
  value       = google_storage_bucket.backups.name
}

output "receipt_bucket_name" {
  description = "Versioned GCS bucket containing deployment evidence."
  value       = google_storage_bucket.receipts.name
}

output "state_prefixes" {
  description = "Backend prefixes with independent managed-folder IAM boundaries."
  value       = { for name, folder in google_storage_managed_folder.state : name => folder.name }
}

output "recovery_state_prefixes" {
  description = "Nested backend prefixes writable only by protected recovery automation."
  value       = { for name, folder in google_storage_managed_folder.recovery_state : name => folder.name }
}

output "automation_service_accounts" {
  description = "Keyless CI service-account emails, keyed by trust boundary."
  value       = { for name, account in google_service_account.automation : name => account.email }
}

output "workload_identity_providers" {
  description = "Canonical Workload Identity Federation provider resource names for GitHub Actions authentication."
  value       = { for name, provider in google_iam_workload_identity_pool_provider.github : name => provider.name }
}

output "secret_ids" {
  description = "Metadata-only Secret Manager containers. Secret versions are deliberately outside OpenTofu state."
  value       = { for name, secret in google_secret_manager_secret.application : name => secret.secret_id }
}
