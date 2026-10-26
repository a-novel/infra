images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.7.1@sha256:b31cb76b7909f052e7bc2d417a32c9c1b15b54bb394059d07bc8709ad7dd48da"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.7.1@sha256:5821b99302b669c8933bc1cd6f8f2b735f4bb5c2e18b16bfc89352264f8718ff"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.7.1@sha256:55b66ddbe064289716f6db1850ba82efc4c1e4372f61ba3c5d51c84f5d30faa7"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.7.1@sha256:552fb8da185c676f8d6a8a3b4f2819838185ec68dff3e8c70525f3c675c7fd37"
}

secret_versions = {
  app-password   = 1
  openai-api-key = 1
  sentry-dsn     = 1
}

backup_repository = {
  cos_image = "projects/cos-cloud/global/images/cos-129-19506-505-8"
  runtime = {
    client_name      = "a-novel-genai-database.a-novel-production-prod"
    ca_version       = "1"
    identity_version = "1"
  }
}

alert_email = "geoffroy.vincent@agorastoryverse.com"
