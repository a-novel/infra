output "trial" {
  description = "Reviewable coordinates, not authorization to provision or execute the proof."
  value = merge(module.repository.trial, {
    instance  = google_compute_instance.trial.name
    zone      = google_compute_instance.trial.zone
    data_disk = google_compute_disk.data.name
    cos_image = var.cos_image
  })
}
