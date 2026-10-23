resource "google_artifact_registry_repository" "production" {
  project  = google_project.workload.project_id
  location = var.region

  repository_id = "agora-production"
  description   = "Verified production OCI images promoted from GitHub Container Registry."
  format        = "DOCKER"
  mode          = "STANDARD_REPOSITORY"

  docker_config {
    immutable_tags = true
  }

  # Cleanup runs in dry-run and deletes nothing. No workflow creates the receipt-* tags the first
  # policy keeps.
  cleanup_policy_dry_run = true

  cleanup_policies {
    id     = "retain-release-receipts"
    action = "KEEP"

    condition {
      tag_prefixes = ["receipt-"]
      tag_state    = "TAGGED"
    }
  }

  cleanup_policies {
    id     = "retain-recent-versions"
    action = "KEEP"

    most_recent_versions {
      keep_count = 10
    }
  }

  cleanup_policies {
    id     = "delete-old-versions"
    action = "DELETE"

    condition {
      older_than = "7776000s"
      tag_state  = "UNTAGGED"
    }
  }

  # The repository lost its last reader in a-novel/infra#1037. This apply unlocks it; the next one
  # deletes it, since the provider reads deletion_policy from state.
  deletion_policy = "DELETE"

  depends_on = [google_project_service.workload["artifactregistry.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
}
