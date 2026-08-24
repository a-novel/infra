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

  # Cleanup remains in dry-run until the release workflow creates receipt-* tags
  # for every rollback digest and verifies the policy preview.
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

  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["artifactregistry.googleapis.com"]]
}

resource "google_artifact_registry_repository_iam_member" "release_writer" {
  project    = google_project.workload.project_id
  location   = google_artifact_registry_repository.production.location
  repository = google_artifact_registry_repository.production.repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${local.automation_service_accounts.release}"
}

# The PostgreSQL VM pulls its pinned container directly. Cloud Run pulls
# same-project images through Google's managed service agent instead of the
# application runtime identity, so no redundant reader grant is added there.
resource "google_artifact_registry_repository_iam_member" "database_reader" {
  project    = google_project.workload.project_id
  location   = google_artifact_registry_repository.production.location
  repository = google_artifact_registry_repository.production.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.runtime["database"].email}"
}
