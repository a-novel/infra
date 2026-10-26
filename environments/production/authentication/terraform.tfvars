images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.18.3@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.18.3@sha256:ab08d35e592b721f289dfbdfd125486084f185f9a5ec8d32b846a8d35bc85c1f"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.18.3@sha256:3a07aa929eca7f813a7700b2550694b03804cee0354e90e62836f87ef100b9bc"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.18.3@sha256:f1252693b43b9c2007c7a258b40bd9dfa32bb16bf62075c3c3f67c922849f30c"
}

secret_versions = {
  app-password = 1
  sentry-dsn   = 1
}

smtp = {
  host              = "smtp-relay.gmail.com"
  sender_email      = "no-reply@agorastoryverse.com"
  sender_name       = "Agora"
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
