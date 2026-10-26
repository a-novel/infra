images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.17.1@sha256:6e8aab13a3f8a3cff10c39f87d8d50a3153dabe88d7da3b20786079239f68ae1"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.17.1@sha256:14de9dee4e6293a5aa0027cce95e310f127e6d8d307c7b5ade2d80bf2ce2f03a"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.17.1@sha256:2eee877e619ae9d7589c0a36c670a9e87fc8517560bfeed8b21d1b41eee59674"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.17.1@sha256:a79130715b02c2cf76335efb400eec502327a36323483d245863a44d5d9855b8"
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
