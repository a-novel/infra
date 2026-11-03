# The cluster root deploys the pin this root validates.
run "rejects_an_unpinned_image" {
  command = plan

  variables {
    images = { web = "ghcr.io/a-novel/platform-studio:latest" }
  }

  expect_failures = [var.images]
}
