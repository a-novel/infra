images = {
  database   = "ghcr.io/a-novel/service-authentication/database:v2.13.2@sha256:024090f703849c1c12fabc7cd78b5abac8ab0df043d64ab31e254ea75c973263"
  migrations = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.13.2@sha256:9fcc82bffa0eedde1cb3d2f9851753c1925c79be9ba5b049f1c515e1058f8b63"
  rest       = "ghcr.io/a-novel/service-authentication/rest:v2.13.2@sha256:d687d8f4227c51cdaa675f18474f10b541633584a7769dae40b3babc051ec668"
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
