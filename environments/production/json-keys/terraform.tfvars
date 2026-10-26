images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.13.6@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.13.6@sha256:94ecccdcaecbe26a408221f0bb8585b22412b166b8277b9348111e07bd47a862"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.13.6@sha256:766deaa64b6ccfcf166eb96de24f1cb7c81c35eebe83e4c1a09608444d4d7ec1"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.13.6@sha256:786d7c4d28ee1b4e27590feecbec6fde153b03e522dbec1539d1eeb5736a3d75"
}

secret_versions = {
  app-password   = 1
  app-master-key = 2
  sentry-dsn     = 1
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
