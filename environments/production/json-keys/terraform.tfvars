images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.13.3@sha256:8778711f5c9beb691b741b2edbbcccf4e5f857b0ff3380fbf2210dea194aab5a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.13.3@sha256:0e87ba3c23beea89873022b9689b5dda4c19f3a1d95db6d06cfdcea6b7d734eb"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.13.3@sha256:a96a284100909d962f6cf4ccf4d284ff7c693d7ba83600826d8ee7c544091859"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.13.3@sha256:01e466bcf37e6c21465b81031e92a9fd8ce8edd7513d46cabd24660d2448dc9e"
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
