# The add-ons' images come through these pull-through caches of their public registries, so the
# cluster pulls only from our Artifact Registry. The cluster root pins each image by digest, so a
# tag moved upstream never changes what runs. Each key spells its registry's host with dashes, and
# Docker Hub serves docker.io's images from its registry host.
locals {
  cluster_image_upstreams = {
    docker-io       = "https://registry-1.docker.io"
    ghcr-io         = "https://ghcr.io"
    quay-io         = "https://quay.io"
    registry-k8s-io = "https://registry.k8s.io"
  }
}

resource "google_artifact_registry_repository" "cluster_upstream" {
  for_each = local.cluster_image_upstreams

  project       = google_project.workload.project_id
  location      = var.cluster_region
  repository_id = "a-novel-${each.key}"
  description   = "Pull-through cache of ${each.value} for the cluster's add-ons."
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description = each.value

    docker_repository {
      custom_repository {
        uri = each.value
      }
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "cluster_upstream_nodes" {
  for_each = google_artifact_registry_repository.cluster_upstream

  project    = each.value.project
  location   = each.value.location
  repository = each.value.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.runtime["cluster_nodes"].member
}

# The databases run each service's PostgreSQL image from its private repository, as its database
# host does, so the nodes read those repositories too.
resource "google_artifact_registry_repository_iam_member" "cluster_database_images" {
  for_each = local.database_image_repositories

  project    = var.workload_project_id
  location   = var.region
  repository = "agora-${each.key}-private-production"
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.runtime["cluster_nodes"].member
}

# Admission admits only images from the workload project. The services with a database run from
# their private repositories there; Studio has none, so it gets one for its cluster release, which
# the cluster root's deploy fills. Foundation applies first, so the repository exists for that copy.
resource "google_artifact_registry_repository" "studio" {
  project         = var.workload_project_id
  location        = var.region
  repository_id   = "agora-studio-private-production"
  format          = "DOCKER"
  mode            = "STANDARD_REPOSITORY"
  deletion_policy = "PREVENT"
  labels          = { environment = "production", service = "studio" }

  # A deployed digest can never be re-tagged to different content.
  docker_config {
    immutable_tags = true
  }

  cleanup_policy_dry_run = true

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["artifactregistry.googleapis.com"]]
}

resource "google_artifact_registry_repository_iam_member" "cluster_studio" {
  project    = google_artifact_registry_repository.studio.project
  location   = google_artifact_registry_repository.studio.location
  repository = google_artifact_registry_repository.studio.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.runtime["cluster_nodes"].member
}

# Inside the perimeter, Artifact Registry reaches no upstream by default. This lets the remote
# repositories above fetch from theirs, and opens nothing else.
resource "google_artifact_registry_vpcsc_config" "workload" {
  provider = google-beta

  project      = google_project.workload.project_id
  location     = var.cluster_region
  vpcsc_policy = "ALLOW"

  # A location has no configuration to set until the project holds a repository there.
  depends_on = [google_artifact_registry_repository.cluster_upstream]
}
