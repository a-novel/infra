mock_provider "google" {}

run "accepts_the_production_defaults" {
  command = plan

  variables {
    workload_project_id = "agora-production-test"
  }

  assert {
    condition     = output.root_name == "release"
    error_message = "The release root identifier changed."
  }

  assert {
    condition     = output.region == "europe-west1"
    error_message = "The production region default changed."
  }
}

run "rejects_an_invalid_project_id" {
  command = plan

  variables {
    workload_project_id = "INVALID"
  }

  expect_failures = [var.workload_project_id]
}
