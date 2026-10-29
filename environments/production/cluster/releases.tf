locals {
  # The release images the cluster runs, by service and role, as each service's root pins them.
  # This root's own deploy copies them into the service's private repository, which the nodes read.
  release_roles = { authentication = ["migrations", "rest"], json-keys = ["grpc", "migrations"] }
  release_pins  = { for service in keys(local.release_roles) : service => local.service_inputs[service].images }
  release_images = { for item in flatten([for service, roles in local.release_roles : [for role in roles : { service = service, role = role }]]) :
    "${item.service}/${item.role}" => merge(
      regex("^ghcr\\.io/a-novel/(?P<path>[^:@]+):(?P<tag>[^@]+)@(?P<digest>sha256:[a-f0-9]{64})$", local.release_pins[item.service][item.role]),
      {
        source     = local.release_pins[item.service][item.role]
        repository = "${data.terraform_remote_state.foundation.outputs.region}-docker.pkg.dev/${data.terraform_remote_state.foundation.outputs.workload_project_id}/agora-${item.service}-private-production"
      },
    )
  }
  release_image = { for key, image in local.release_images : key => "${image.repository}/${image.path}@${image.digest}" }

  # A planned downtime listing one of a service's components stops its workloads from its start.
  downtime     = try(jsondecode(var.downtime), null)
  downtime_env = { for service in keys(local.release_roles) : service => anytrue([for component in try(local.downtime.components, []) : startswith(component, "service-${service}.")]) ? { DOWNTIME_START = local.downtime.start } : {} }

  # Each service's workloads verify the service tokens the cluster signs.
  service_token_issuer = "https://container.googleapis.com/v1/projects/${data.terraform_remote_state.foundation.outputs.workload_project_id}/locations/${local.cluster.location}/clusters/${local.cluster.name}"
  # Each workload reads its database's credentials from CloudNativePG's Secret, and verifies the
  # database's certificate against this name.
  database_env = { for service in keys(var.databases) : service => {
    POSTGRES_HOST     = "database-rw.${service}.svc"
    POSTGRES_PORT     = "5432"
    POSTGRES_DATABASE = "app"
  } }
  database_secret_env = {
    POSTGRES_USER     = { secret = "database-app", key = "username" }
    POSTGRES_PASSWORD = { secret = "database-app", key = "password" }
  }
}

output "image_copies" {
  description = "Images the deploy workflow verifies and copies to Artifact Registry before apply."
  value = [for image in values(local.release_images) : {
    source   = image.source
    producer = "a-novel/${split("/", image.path)[0]}"
    target   = "${image.repository}/${image.path}:${image.tag}"
  }]
}
