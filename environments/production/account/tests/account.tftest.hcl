# The cluster root deploys the pin this root validates.
run "rejects_an_unpinned_image" {
  command = plan

  variables {
    images = { web = "ghcr.io/a-novel/platform-account:latest" }
  }

  expect_failures = [var.images]
}
