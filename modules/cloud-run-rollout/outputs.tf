output "rollout" {
  description = "Native resource identities for the future service-specific release submitter."
  value = {
    pipeline = google_clouddeploy_delivery_pipeline.service.id
    target   = google_clouddeploy_target.service.id
  }
}

output "execution_service_accounts" {
  description = "Module-owned deploy, verify and probe identities for ownership inventory and effective-IAM verification."
  value       = { for name, account in google_service_account.execution : name => account.email }
}
