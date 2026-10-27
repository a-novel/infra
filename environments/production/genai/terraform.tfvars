images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.7.3@sha256:880e760f2f03f4ffdaf2affc186d10a91a12f711602a4c0983a9d70d837efb70"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.7.3@sha256:81dbb53d51276688bfaf07df8560fff9fd0984ea7fbbd078923809965697770c"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.7.3@sha256:4f8d30b89977d421338a39a26503c4d6004d0ff83c128bfd3e8427a8efaa32b7"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.7.3@sha256:f65a35579a64dc0fb8613a8bb84daa933fcb31231be4de89e916dcfaa32e75a1"
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
