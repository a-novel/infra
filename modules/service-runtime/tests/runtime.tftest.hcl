mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email  = "agora-genai-private@agora-test.iam.gserviceaccount.com"
      member = "serviceAccount:agora-genai-private@agora-test.iam.gserviceaccount.com"
      name   = "projects/agora-test/serviceAccounts/agora-genai-private@agora-test.iam.gserviceaccount.com"
    }
  }
}

variables {
  service               = "genai"
  zone                  = "private"
  project_id            = "agora-test"
  region                = "europe-west1"
  management_project_id = "agora-management-test"
  secrets               = []
  deployer              = "infra-foundation@agora-management-test.iam.gserviceaccount.com"
  alert_email           = "operations@example.test"
}

# A database host without native backups once had no grant, and its startup could not pull PostgreSQL.
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
