locals {
  name = "agora-${var.service}-private"
}

# The cluster runs every release from the production repository.
resource "google_artifact_registry_repository" "images" {
  for_each = toset(["production"])

  project         = var.project_id
  location        = var.region
  repository_id   = "${local.name}-${each.key}"
  format          = "DOCKER"
  mode            = "STANDARD_REPOSITORY"
  deletion_policy = "PREVENT"
  labels          = { environment = "production", service = var.service }

  # A deployed digest can never be re-tagged to different content.
  docker_config {
    immutable_tags = true
  }

  cleanup_policy_dry_run = true

  lifecycle {
    prevent_destroy = true
  }
}

# The tooling repository held the database hosts' tools, and retires with them (a-novel/infra#1208).
moved {
  from = google_artifact_registry_repository.images["tooling"]
  to   = google_artifact_registry_repository.tooling
}

removed {
  from = google_artifact_registry_repository.tooling

  lifecycle {
    destroy = true
  }
}
