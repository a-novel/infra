images = {
  database   = "ghcr.io/a-novel/service-authentication/database:v2.12.0@sha256:a1e2630f014e889357c201e81db468831b51d9f1b320c7c7d07a9ec6b10596b4"
  migrations = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.12.0@sha256:a2fe27a3bfe2a63e1d01308436684ad5380cabfb31e132b434df39998cd82567"
  rest       = "ghcr.io/a-novel/service-authentication/rest:v2.12.0@sha256:636603b149ce28207f27ad64e09a09e118b51e758232124bf370358ba1b3af40"
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
