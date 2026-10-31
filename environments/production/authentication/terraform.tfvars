images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.19.2@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.19.2@sha256:8c2ff87b36c2450c93dfc5396a9d293826e18e27ae8f0c1441b4cdcb3c2c34e8"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.19.2@sha256:bbbd53adbf877d88262b52cfc9db31d93ddab5efd8b7cb3a7497dd22be17d79f"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.19.2@sha256:e901bfd4308c2c558f392313910d3188d2bc17f0482cca442198c014902abad4"
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
