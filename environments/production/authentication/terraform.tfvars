images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.18.5@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.18.5@sha256:2cde7adc095d1817db8b25e82de77fc311279f104365c70222862229a9ec1560"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.18.5@sha256:2434d78f1a0ad2ff9b5b4ab69d1db93575ea2e9c02a4122601300c3ea3f81ea1"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.18.5@sha256:4574baf2924279536f5593eef3323b6a724864dd7ee82dea2f27f8a109f1ce3f"
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
