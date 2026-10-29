images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.19.0@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.19.0@sha256:dba479cf34326e7e85cdd4d8dad40fd97e8aa9c90b0310f2d03bcd9c2993abaa"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.19.0@sha256:0a071b76e13196e6498bda9d82a0f6ea64db2d7ef7374a0f4156994446d896e9"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.19.0@sha256:7ffa982e4574d09ed26ec1e9e34826396c35a963650a523ccb4e2ea26c4c0b63"
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
