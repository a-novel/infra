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

# The cluster root deploys the pins this root validates.
run "rejects_an_unpinned_image" {
  command = plan

  variables {
    images = {
      database   = "ghcr.io/a-novel/service-genai/database:v0.5.0@sha256:f5af5d12a188072da1e51ab51b5b2aef3c28be5941ed5b9dc48e0780d45bf453"
      grpc       = "ghcr.io/a-novel/service-genai/grpc:latest"
      migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.5.0@sha256:f5af5d12a188072da1e51ab51b5b2aef3c28be5941ed5b9dc48e0780d45bf453"
      sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.5.0@sha256:279ca54fb7c4b277056d15c1d26dc1930e07b19b9a2cce21f9542f23c6c63a07"
    }
  }

  expect_failures = [var.images]
}
