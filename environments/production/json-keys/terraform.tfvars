images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.13.9@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.13.9@sha256:e0c93d89e9c08629b9d7eb4aaf8bdb9d4ad90fec24839c49b7601bf98ee7ccd2"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.13.9@sha256:8e7523a74ffcff0b4ef6d39428e56e04fb164d92edeab27fe5c510f90a0580aa"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.13.9@sha256:6e1b882291493f8fd5b2a62c354f731426c539a3ccc4983323e8aa74f7654695"
}


secret_versions = {
  app-password   = 1
  app-master-key = 2
}

backup_repository = {
  cos_image = "projects/cos-cloud/global/images/cos-129-19506-505-8"
  runtime = {
    client_name      = "agora-database.a-novel-production-prod"
    ca_version       = "1"
    identity_version = "2"
  }
}

alert_email = "geoffroy.vincent@agorastoryverse.com"
