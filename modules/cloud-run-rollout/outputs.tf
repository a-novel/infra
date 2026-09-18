output "rollout" {
  description = "Native resource identities for the future service-specific release submitter."
  value = {
    pipeline = google_clouddeploy_delivery_pipeline.service.id
    target   = google_clouddeploy_target.service.id
  }
}
