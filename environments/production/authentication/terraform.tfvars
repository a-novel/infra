images = {
  database   = "ghcr.io/a-novel/service-authentication/database:v2.11.0@sha256:78bcd4cba6aa60c37e46fad0b8625c8424d118014fc5efa645e0bdee05a8d871"
  migrations = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.11.1@sha256:2b44d82e3824aed7d297fd82c5716110cff6b449debaeda77189e8bbba7a66b9"
  rest       = "ghcr.io/a-novel/service-authentication/rest:v2.11.1@sha256:0695325c58b248c6df11a9b92dd26a801f48cc7548642993e28fbd2d3102f055"
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
    credentials_image = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-authentication-private-tooling/host-credentials@sha256:a5e264fc51c824c52fb6fd59b035e14e52fdc9f77e47b0375b352d8ad9bfd00d"
    client_name       = "agora-authentication-database.a-novel-production-prod"
    ca_version        = "1"
    identity_version  = "1"
  }
}

alert_email = "geoffroy.vincent@agorastoryverse.com"
