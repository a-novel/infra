images = {
  database   = "ghcr.io/a-novel/service-authentication/database:v2.14.0@sha256:024090f703849c1c12fabc7cd78b5abac8ab0df043d64ab31e254ea75c973263"
  migrations = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.14.0@sha256:1869bbfd5c177534aa69db66f78c1ef7de679749c29f6e7dd4590f852faa7ce4"
  rest       = "ghcr.io/a-novel/service-authentication/rest:v2.14.0@sha256:129c04b6f8b25a171fd74356fd18c86e5dab9b23a8a7a7dcce6b14f2cfbce2fb"
}

secret_versions = {
  postgres-password    = 2
  smtp-sender-password = 4
}

smtp = {
  host              = "smtp-relay.gmail.com"
  username          = "geoffroy.vincent@agorastoryverse.com"
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
