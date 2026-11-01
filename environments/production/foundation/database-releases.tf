variable "database_images" {
  description = "Database image of each service as ghcr.io/a-novel/<path>:<tag>@<digest>, which its cluster database runs."
  type        = map(string)
  nullable    = false

  validation {
    condition = alltrue([for service, ref in var.database_images :
      can(regex("^ghcr\\.io/a-novel/service-${service}/database:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$", ref))
    ])
    error_message = "Pin each service's database image by release tag and digest."
  }
}

locals {
  database_images = { for service, ref in var.database_images : service => merge(
    regex("^ghcr\\.io/a-novel/(?P<path>[^:@]+):(?P<tag>[^@]+)@(?P<digest>sha256:[a-f0-9]{64})$", ref),
    { source = ref },
  ) }
  # Each database runs PostgreSQL from its service's own private repository.
  database_image_repositories = {
    for service in keys(var.database_images) : service => "${var.region}-docker.pkg.dev/${var.workload_project_id}/agora-${service}-private-production"
  }
  database_image = {
    for service, image in local.database_images : service => "${local.database_image_repositories[service]}/${image.path}@${image.digest}"
  }
}

output "image_copies" {
  description = "Images the deploy workflow verifies against their producer's workflow and copies to Artifact Registry before apply."
  value = [for service, image in local.database_images : {
    source   = image.source
    producer = "a-novel/service-${service}"
    workflow = "release.yaml"
    target   = "${local.database_image_repositories[service]}/${image.path}:${image.tag}"
  }]
}
