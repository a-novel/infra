images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.7.2@sha256:880e760f2f03f4ffdaf2affc186d10a91a12f711602a4c0983a9d70d837efb70"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.7.2@sha256:c7ac1bf396d49e944b8b8e2e2efa4b9c9de3e2d0fa6f4da8129964ae137ad633"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.7.2@sha256:a8089451638820b92a0bb98acb9b3168c73813e55b9f4c1ad52a87435970e61c"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.7.2@sha256:449952c44af5516bc255f66eac2f55ba972f0ca625bdca6422705bae3302c34a"
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
