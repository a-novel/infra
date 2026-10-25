images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.15.3@sha256:6e8aab13a3f8a3cff10c39f87d8d50a3153dabe88d7da3b20786079239f68ae1"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.15.3@sha256:cc68e16849b7f5a8b5a17dfc7ab86d2d4f0be0ff0d55a3db17496dac8b351fdf"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.15.3@sha256:e604bc6e1f1829226bec7069a29694897b846b3207624a07dde94b45cac91ea5"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.15.3@sha256:798f228e2b8ae2a4528c7a4df5f3ed3d2f3e56740483012f34a1839954b5c73c"
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
