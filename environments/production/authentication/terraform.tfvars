images = {
  migrations = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.11.0@sha256:13e3c1521511586d03d0db3a3c46a77e2c3167f25eaf3a68218d690badaa3c30"
  rest       = "ghcr.io/a-novel/service-authentication/rest:v2.11.0@sha256:089a2d3a514d59c816f6a5cda0d59987b25a6c0d35154578a73f0fc93f5ae41d"
}

secret_versions = {
  postgres-password    = 2
  smtp-sender-password = 4
}

smtp = {
  host              = "smtp-relay.gmail.com"
  username          = "geoffroy.vincent@agorastoryverse.com"
  sender_email      = "no-reply@agorastoryverse.com"
  sender_name       = "Agora Storyverse"
  platform_auth_url = "https://www.agorastoryverse.com"
}

backup_repository = {
  cos_image = "projects/cos-cloud/global/images/cos-129-19506-505-8"
  runtime = {
    server_image      = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-authentication-private-production/service-authentication/database@sha256:78bcd4cba6aa60c37e46fad0b8625c8424d118014fc5efa645e0bdee05a8d871"
    credentials_image = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-authentication-private-tooling/host-credentials@sha256:a5e264fc51c824c52fb6fd59b035e14e52fdc9f77e47b0375b352d8ad9bfd00d"
    client_name       = "agora-authentication-database.a-novel-production-prod"
    ca_version        = "1"
    identity_version  = "1"
  }
}

alert_email = "geoffroy.vincent@agorastoryverse.com"
