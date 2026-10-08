variable "database_images" {
  description = "Database image of each service as ghcr.io/a-novel/<path>:<tag>@<digest>. Hosts pull it only when rolled."
  type        = map(string)
  nullable    = false

  validation {
    condition = alltrue([for service, ref in var.database_images :
      can(regex("^ghcr\\.io/a-novel/service-${service}/database:v[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64}$", ref))
    ])
    error_message = "Pin each service's database image by release tag and digest."
  }
}

variable "database_releases" {
  description = "Existing numeric password version and release marker of each database host."
  type = map(object({
    revision         = string
    password_version = string
  }))
  default  = {}
  nullable = false

  validation {
    condition = length(var.database_releases) == 0 || (
      toset(keys(var.database_releases)) == toset(["json-keys", "authentication"]) &&
      alltrue([for service, release in var.database_releases :
        can(regex("^[a-f0-9]{40}$", release.revision)) &&
        can(regex("^[1-9][0-9]*$", release.password_version))
      ])
    )
    error_message = "Supply both database releases with revisions and numeric credential versions."
  }
}

locals {
  database_images = { for service, ref in var.database_images : service => merge(
    regex("^ghcr\\.io/a-novel/(?P<path>[^:@]+):(?P<tag>[^@]+)@(?P<digest>sha256:[a-f0-9]{64})$", ref),
    { source = ref },
  ) }
  # The host runs PostgreSQL from the foundation repository and its backup
  # containers from the service's private repository; both copies share a digest.
  database_image_repositories = { for service in keys(var.database_images) : service => {
    host   = "${var.region}-docker.pkg.dev/${var.workload_project_id}/agora-production"
    backup = "${var.region}-docker.pkg.dev/${var.workload_project_id}/agora-${service}-private-production"
  } }
  database_image = { for service, image in local.database_images : service => {
    for use, repository in local.database_image_repositories[service] : use => "${repository}/${image.path}@${image.digest}"
  } }
}

output "image_copies" {
  description = "Database images the deploy workflow verifies and copies to Artifact Registry before apply."
  value = flatten([for service, image in local.database_images : [
    for repository in values(local.database_image_repositories[service]) : {
      source   = image.source
      producer = "a-novel/service-${service}"
      target   = "${repository}/${image.path}:${image.tag}"
    }
  ]])
}
