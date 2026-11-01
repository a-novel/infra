mock_provider "google" {}

variables {
  service     = "genai"
  project_id  = "agora-test"
  region      = "europe-west1"
  alert_email = "operations@example.test"
}

# Every database host pulls its PostgreSQL image, with or without native backups.
run "lets_the_database_host_pull_its_own_images" {
  command = plan

  variables {
    database_service_account = "agora-genai-database@agora-test.iam.gserviceaccount.com"
  }

  assert {
    condition = {
      for purpose, grant in google_artifact_registry_repository_iam_member.database : purpose => [grant.repository, grant.role, grant.member]
      } == {
      production = ["agora-genai-private-production", "roles/artifactregistry.reader", "serviceAccount:agora-genai-database@agora-test.iam.gserviceaccount.com"]
      tooling    = ["agora-genai-private-tooling", "roles/artifactregistry.reader", "serviceAccount:agora-genai-database@agora-test.iam.gserviceaccount.com"]
    }
    error_message = "The database host must read both of its service's repositories, and nothing else."
  }
}

run "grants_nothing_without_a_database_host" {
  command = plan

  assert {
    condition     = length(google_artifact_registry_repository_iam_member.database) == 0
    error_message = "A service without a database host must grant no pull."
  }
}
