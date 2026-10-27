output "service_account" {
  description = "Studio's runtime identity, which the services it calls admit as their invoker."
  value       = module.runtime.service_account
}

output "image_copies" {
  description = "Images the deploy workflow verifies and copies to Artifact Registry before apply. Studio pins none until its repositories exist."
  value       = []
}
