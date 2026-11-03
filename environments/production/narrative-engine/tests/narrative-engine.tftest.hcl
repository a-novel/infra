# The cluster root deploys the pins this root validates.
run "rejects_an_unpinned_image" {
  command = plan

  variables {
    images = {
      database   = "ghcr.io/a-novel/service-narrative-engine/database:v1.0.0@sha256:fe5012f68d1bfc9d7be5c9be0f304c0b54d743ed59310b67ebac1a56eca9b61a"
      migrations = "ghcr.io/a-novel/service-narrative-engine/jobs/migrations:v1.0.0@sha256:b7287b780514b34d283c2c421f3ac1da953650d08a44333c741d31765fb13910"
      rest       = "ghcr.io/a-novel/service-narrative-engine/rest:latest"
    }
  }

  expect_failures = [var.images]
}
