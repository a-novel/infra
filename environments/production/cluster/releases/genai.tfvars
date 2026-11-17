images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.12.1@sha256:9aafca234ebd25ca3db0f29546264d6f748e1f3b2ab500006364c6af8c6292d9"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.12.1@sha256:7a550924e0d117970d74b99567d37460c39e78921659d90721ca910c399226b0"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.12.1@sha256:60464f6f69d20e652b55a0bdd1092199d3892e6ae195857d6aad20f4aa859542"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.12.1@sha256:15f419d9f3afbec8457b1367279225aa420e808aebcb57f5f1d8f6711c059df7"
}

secret_versions = {
  openai-api-key = 1
}
