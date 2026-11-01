mock_provider "google" {}

variables {
  service    = "genai"
  project_id = "agora-test"
  region     = "europe-west1"
}

run "keeps_the_production_repository" {
  command = plan

  assert {
    condition     = keys(google_artifact_registry_repository.images) == ["production"] && google_artifact_registry_repository.images["production"].deletion_policy == "PREVENT"
    error_message = "The service keeps only its protected production repository, which the cluster pulls from."
  }
}
