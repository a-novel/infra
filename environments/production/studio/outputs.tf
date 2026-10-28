output "service_account" {
  description = "Studio's runtime identity, which the services it calls admit as their invoker."
  value       = module.runtime.service_account
}

output "url" {
  description = "The URL Studio serves on, which Authentication's email links name."
  value       = google_cloud_run_v2_service.web.uri
}

output "image_copies" {
  description = "Images the deploy workflow verifies and copies to Artifact Registry before apply."
  value = [for role, image in local.images : {
    source   = image.source
    producer = "a-novel/${split("/", image.path)[0]}"
    target   = "${module.runtime.repositories["production"]}/${image.path}:${image.tag}"
  }]
}
