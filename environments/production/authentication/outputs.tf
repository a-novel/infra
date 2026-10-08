output "image_copies" {
  description = "Images the deploy workflow verifies and copies to Artifact Registry before apply."
  value = [for role, image in local.images : {
    source   = image.source
    producer = "a-novel/${split("/", image.path)[0]}"
    target   = "${image.runtime.repositories["production"]}/${image.path}:${image.tag}"
  }]
}

output "url" {
  description = "Public REST API URL, used by the post-deploy health check."
  value       = google_cloud_run_v2_service.rest.uri
}
