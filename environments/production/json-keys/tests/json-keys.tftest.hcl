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
      database   = "ghcr.io/a-novel/service-json-keys/database:v2.8.0@sha256:95dd4bb962d5345f171b718dcd888d6bc11e1856022d442a8a80be4a6bdc86f6"
      grpc       = "ghcr.io/a-novel/service-json-keys/grpc:latest"
      migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.8.0@sha256:95dd4bb962d5345f171b718dcd888d6bc11e1856022d442a8a80be4a6bdc86f6"
      rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.8.0@sha256:d7eb0811340b903a7d9a20b75911711f8d35b95687250792c167777be7aeac6c"
    }
  }

  expect_failures = [var.images]
}
