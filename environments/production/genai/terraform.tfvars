images = {
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.6.2@sha256:edcf8b410bb867c59b1f60a2cb25aff22928b443b3bc973101f01a241c33c73f"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.6.2@sha256:eb297f3dbbb96bf78ce347873cf7d0718b3ccab730ad05f10bd6943a4054e8ba"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.6.2@sha256:4a1ccb5d085175a94858c66de79a475ad7ef89e017ae229f2f36620b5bafeb9a"
}

secret_versions = {
  app-password   = 1
  openai-api-key = 1
}

alert_email = "geoffroy.vincent@agorastoryverse.com"
