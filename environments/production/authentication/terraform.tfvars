images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.15.1@sha256:c4d8cb051e88c721912037537e6546694736f8f0183cc59994c230369fbc593c"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.15.1@sha256:9e117772e06f2e6fb0b5e78e9d18d78ccc76d815b4b0d945deed9afa1de944ed"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.15.1@sha256:e956610bd3a100deaff2d7f10754be29dc9d66d2f36d14d9703ae3cfb499840e"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.15.1@sha256:688ba100d22122313373d56bed2ab006be7edf8b70dc4e3bc54b1dfd4504470d"
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
