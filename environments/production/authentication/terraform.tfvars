images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.19.1@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.19.1@sha256:81aa9d258c460357687f51f41d1ed2bbf89f580094a26f169313508c1e4a8722"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.19.1@sha256:629c60b1e54a46da2c838908847f7568632bc1ff9dbf46ec7048a41bc1aaa735"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.19.1@sha256:85df278b27e65452c99abaa3b65fb804d58de0b3ad8525a01047f242ee4e5d69"
}


secret_versions = {
  app-password = 1
}

smtp = {
  host         = "smtp-relay.gmail.com"
  sender_email = "no-reply@agorastoryverse.com"
  sender_name  = "Agora"
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
