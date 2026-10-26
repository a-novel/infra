images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.17.0@sha256:6e8aab13a3f8a3cff10c39f87d8d50a3153dabe88d7da3b20786079239f68ae1"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.17.0@sha256:e859c3d79e99749b705bc6ebeffb4499ce8a06b67b43c4f4c5d887a930f03787"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.17.0@sha256:9c3c41fc05df91a4d25605c9c0639d52eba3f30236c7f1b4c8440b0eb8bd4732"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.17.0@sha256:fe13bb845c56eaa2453ff9b8556a1a3bc657f1aae02c4444ff902d9d75ff1028"
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
