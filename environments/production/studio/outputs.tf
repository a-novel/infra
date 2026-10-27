output "service_account" {
  description = "Studio's runtime identity, which the services it calls admit as their invoker."
  value       = module.runtime.service_account
}

output "address" {
  description = "The load balancer's IPv4 address, which the domain's DNS A record names."
  value       = google_compute_global_address.web.address
}

output "image_copies" {
  description = "Images the deploy workflow verifies and copies to Artifact Registry before apply."
  value = [for role, image in local.images : {
    source   = image.source
    producer = "a-novel/${split("/", image.path)[0]}"
    target   = "${module.runtime.repositories["production"]}/${image.path}:${image.tag}"
  }]
}
