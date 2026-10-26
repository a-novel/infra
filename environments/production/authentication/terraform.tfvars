images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.18.2@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.18.2@sha256:741389ffe54000eb13e25e5a0a52c8053aff00ebe40b5593bc5f04ff0682d2be"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.18.2@sha256:4499a1bdcfc98ab79806ae8adc0e6942386bc0d4de41cbf25c31641187bfcfbb"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.18.2@sha256:8da392ee7498ad49abbf3693da67c44295225f470a32ccc21623420c66f9c3bc"
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
