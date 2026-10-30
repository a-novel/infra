images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.8.1@sha256:880e760f2f03f4ffdaf2affc186d10a91a12f711602a4c0983a9d70d837efb70"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.8.1@sha256:75c5fbc0d7ba1d71e90236bedce8cffc2d279e0bb458f818dadad21cd718e4fb"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.8.1@sha256:bebe8bdb76784ade4d59ff833af88ed7ebfccad0b624e9d1a52e4f05e2fca97a"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.8.1@sha256:ddeea626149e6113c1867ecd89cde6545e33de34255219580d5f81bdeaedf410"
}


secret_versions = {
  app-password   = 1
  openai-api-key = 1
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
