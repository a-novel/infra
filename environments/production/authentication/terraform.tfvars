images = {
  database   = "ghcr.io/a-novel/service-authentication/database:v2.13.0@sha256:a1e2630f014e889357c201e81db468831b51d9f1b320c7c7d07a9ec6b10596b4"
  migrations = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.13.0@sha256:a683aac13bfb57829c987aa83aafc3d76588a0f8160dd05dde8460f7e3ee9745"
  rest       = "ghcr.io/a-novel/service-authentication/rest:v2.13.0@sha256:9be54a5b5df3ddfc83063ed61deff3be853dea468f65ae3a975d66aaf9155671"
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
