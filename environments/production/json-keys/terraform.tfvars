images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.13.2@sha256:8778711f5c9beb691b741b2edbbcccf4e5f857b0ff3380fbf2210dea194aab5a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.13.2@sha256:4e670dae2c3285c8cce83790f51c31d8ddc4c64d7562df24ea31afecc4b95554"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.13.2@sha256:02c5fdd3bb7ee7ac5b7c092cf6e828dc097772072d3a13e0912174ca56caefd8"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.13.2@sha256:bee1d86c325bdbb1b010cdc9cc11c4cd3f5bb45b5d29b8360661dd233f27251b"
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
