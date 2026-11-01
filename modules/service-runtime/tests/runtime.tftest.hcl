mock_provider "google" {}

variables {
  service    = "genai"
  project_id = "agora-test"
  region     = "europe-west1"
}

run "unlocks_the_production_repository" {
  command = plan

  assert {
    condition     = keys(google_artifact_registry_repository.images) == ["production"] && google_artifact_registry_repository.images["production"].deletion_policy == "DELETE"
    error_message = "The service keeps only its production repository, unlocked so that a-novel/infra#1208 can delete it."
  }
}
