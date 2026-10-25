images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.16.0@sha256:6e8aab13a3f8a3cff10c39f87d8d50a3153dabe88d7da3b20786079239f68ae1"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.16.0@sha256:35146ffa5e74eedf3966d6087e2769367f8b037e5bf1f14563fa45300922192c"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.16.0@sha256:248dd693063ab0af1a2db8ccfab7da74571b4b547c194ef64a3345a697274547"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.16.0@sha256:80c2f3c8e5f94609b557786a7756d15ab88c99f3236809ed3c77162283edc72d"
}

secret_versions = {
  app-password = 1
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
