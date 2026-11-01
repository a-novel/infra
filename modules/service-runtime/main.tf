locals {
  name = "agora-${var.service}-private"
}

# The cluster ran every release from the production repository until its releases moved to the
# cluster's region. Unlocked, it retires with a-novel/infra#1208.
resource "google_artifact_registry_repository" "images" {
  for_each = toset(["production"])

  project         = var.project_id
  location        = var.region
  repository_id   = "${local.name}-${each.key}"
  format          = "DOCKER"
  mode            = "STANDARD_REPOSITORY"
  deletion_policy = "DELETE"
  labels          = { environment = "production", service = var.service }

  # A deployed digest can never be re-tagged to different content.
  docker_config {
    immutable_tags = true
  }

  cleanup_policy_dry_run = true
}
