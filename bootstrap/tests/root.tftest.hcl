mock_provider "google" {}

run "accepts_the_management_defaults" {
  command = plan

  variables {
    management_project_id = "agora-management-test"
  }

  assert {
    condition     = output.root_name == "bootstrap"
    error_message = "The bootstrap root identifier changed."
  }

  assert {
    condition     = output.region == "europe-west1"
    error_message = "The bootstrap region default changed."
  }
}

run "rejects_an_invalid_project_id" {
  command = plan

  variables {
    management_project_id = "INVALID"
  }

  expect_failures = [var.management_project_id]
}
