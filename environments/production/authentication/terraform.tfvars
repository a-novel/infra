images = {
  database   = "ghcr.io/a-novel/service-authentication/database:v2.13.1@sha256:a1e2630f014e889357c201e81db468831b51d9f1b320c7c7d07a9ec6b10596b4"
  migrations = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.13.1@sha256:8188a7f9c142bc887b67b73b077892e2d1bd0a6e83c03291bc8ecb53a32a3703"
  rest       = "ghcr.io/a-novel/service-authentication/rest:v2.13.1@sha256:07eb3bd9c90cccf59f178c188bfbf4143a5459c89821250949a62151636329dc"
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
    client_name      = "agora-authentication-database.a-novel-production-prod"
    ca_version       = "1"
    identity_version = "1"
  }
}

alert_email = "geoffroy.vincent@agorastoryverse.com"
