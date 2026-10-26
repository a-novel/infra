images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.18.0@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.18.0@sha256:d137852d725196890e7539927005d374df286ce7f788cb79d615798d9811be6e"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.18.0@sha256:eada3c096fd203141bda0936f47b1f8409f2d960e245f7d97413d86613383c93"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.18.0@sha256:be21630075c4b6d6473ce46e7ee0a6c4e250acc42047755b97d43b50eb3cd1f8"
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
