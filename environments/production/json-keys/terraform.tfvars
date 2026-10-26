images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.13.5@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.13.5@sha256:36b802044bf83f1554fd3bed0da88b69ed803013e66143638cd1255dae288058"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.13.5@sha256:8de7908512b7fc7e8b3708fa7be84a93b072e3677f5c3596b0d226192eca48a8"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.13.5@sha256:034cfbec9673b7270847472818fab8c5cbf486c97d7c47b63341bf884971f30d"
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
