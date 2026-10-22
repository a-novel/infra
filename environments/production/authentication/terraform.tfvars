images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.15.0@sha256:c4d8cb051e88c721912037537e6546694736f8f0183cc59994c230369fbc593c"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.15.0@sha256:963ba6af96271a1bb36b6c44e2b2f43cd848957093ee6c57c430f9c4facd658f"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.15.0@sha256:954921896737c5aa5eff0a2a620d33094726471cae6751d2a9c64b0c1c56db3b"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.15.0@sha256:935bbe1e29de1bace2cc2d4af850cb68f17a9faea93678b406eb77d60e464f9f"
}

secret_versions = {
  app-password         = 1
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
