# The cluster root deploys the pins this root validates.
run "rejects_an_unpinned_image" {
  command = plan

  variables {
    images = {
      database   = "ghcr.io/a-novel/service-profile/database:v1.0.0@sha256:1111111111111111111111111111111111111111111111111111111111111111"
      migrations = "ghcr.io/a-novel/service-profile/jobs/migrations:v1.0.0@sha256:2222222222222222222222222222222222222222222222222222222222222222"
      rest       = "ghcr.io/a-novel/service-profile/rest:latest"
    }
  }

  expect_failures = [var.images]
}
