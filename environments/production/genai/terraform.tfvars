images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.8.0@sha256:880e760f2f03f4ffdaf2affc186d10a91a12f711602a4c0983a9d70d837efb70"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.8.0@sha256:578c924861092aa99dcf353d1265e55fbd2d23f6797a75a7f42bbf0cef6d11ec"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.8.0@sha256:6e8a4de2228677504e3042f8dfb9106173e516513db1779662d6539d3e9d00d2"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.8.0@sha256:706eeeb52245baad259ac0676c0f7159f130d86761bad8286298adbe2237044f"
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
