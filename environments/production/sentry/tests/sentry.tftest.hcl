# Plans the committed production inputs against mocked providers.
mock_provider "google" {}

mock_provider "sentry" {}

run "plans_with_the_read_only_token" {
  command = plan

  assert {
    condition     = local.token.secret == "production-sentry-plan-token"
    error_message = "Pull requests and the drift check run pull-request code, so they must read only the read-only token."
  }
}

run "deploys_with_the_write_token" {
  command = plan

  variables {
    writer = true
  }

  assert {
    condition     = local.token.secret == "production-sentry-deploy-token"
    error_message = "Only a deploy may read the token that writes."
  }
}
