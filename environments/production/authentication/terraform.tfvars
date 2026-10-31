images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.20.0@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.20.0@sha256:4597fac2064d9bb0d8eb92ca4b08a4e9a8b0f17398e1c9910f16768141f56954"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.20.0@sha256:864bc97a6b86edb59fd4ff5bdc552e03eb3df3204d0c0980036703620a470aef"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.20.0@sha256:cffe16c56009ccb0582399d47abd002eaa7d2f75f488ea64b07019857b4e4d3c"
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
