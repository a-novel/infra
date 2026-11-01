mock_provider "google" {}

override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = {
      region              = "europe-west1"
      workload_project_id = "a-novel-production-prod"
    }
  }
}

# The cluster root deploys the pin this root validates.
run "rejects_an_unpinned_image" {
  command = plan

  variables {
    images = { web = "ghcr.io/a-novel/platform-studio:latest" }
  }

  expect_failures = [var.images]
}
