images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.15.2@sha256:a1a1536d9ac14aa037ee0df45f297ed5bcc86f6788badedef8d0434f13e28c2e"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.15.2@sha256:4939507e57376e63395135b68d1aeebcea12672f9941c38a5f2a68d16f5717e2"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.15.2@sha256:4d6750f836df87f67b019e7ad11bca5527d9443ee96ac73f64c7ab25096e9d21"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.15.2@sha256:c9f031ed95f7b6d2e674d9c57bc356da56853483b6c2efac9ab44419d3dc5724"
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
