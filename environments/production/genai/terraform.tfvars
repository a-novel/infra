images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.7.4@sha256:880e760f2f03f4ffdaf2affc186d10a91a12f711602a4c0983a9d70d837efb70"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.7.4@sha256:1addd9ad74ce419e4624563b60d0217a20dc9f57c291f58e872be52b7132d65b"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.7.4@sha256:b51b10e271d29e67aeed16ec37ae06a93920ce4b50b3491ce87ee4c16a3187da"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.7.4@sha256:e714d9ab5be10c6c1cac620a2a338c42f1e608c4d7b3a0ff54655d2639a513da"
}

sentry_project_id = "4512319624314880"

secret_versions = {
  app-password        = 1
  openai-api-key      = 1
  sentry-dsn          = 1
  sentry-otlp-headers = 1
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
