output "trial" {
  description = "Review against independently approved scope before running the human-only storage trial."
  value = {
    project_id        = var.project_id
    service           = var.service
    bucket            = google_storage_bucket.trial[var.service].name
    peer_bucket       = google_storage_bucket.trial["peer"].name
    writer            = google_service_account.trial["writer"].email
    recovery          = google_service_account.trial["recovery"].email
    retention_seconds = var.retention_seconds
  }
}
