images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.18.4@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.18.4@sha256:c03a4999193a0fe2b14512c7b72a4af12a915da457e824040e4bd93a42106612"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.18.4@sha256:c1aaa6ef4496850622d9e53c233389923ae922b2b975e88b553c4c7e096a25c7"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.18.4@sha256:bb26148a4ca3bd6cc40ccb3e9cb447fabf57b9a3d7800959d225641b2c2b2eb2"
}

sentry_project_id = "4512319614156800"

secret_versions = {
  app-password        = 1
  sentry-dsn          = 1
  sentry-otlp-headers = 1
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
