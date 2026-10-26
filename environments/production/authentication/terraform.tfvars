images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.18.1@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.18.1@sha256:fa08705dafaba48e6d36de277f5b7e804deb4a4ab691b4292f3b12fddfb1d485"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.18.1@sha256:ad53990e93d7328aa2fbfec7aa9eb3e4f58528afda0a773776b5d7fc75ac7ecf"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.18.1@sha256:e39cf94b8b75da763c6548e49f1dfdcd00f3fcfc37b09327c1f469a1149090f4"
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
