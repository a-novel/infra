images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.13.4@sha256:8778711f5c9beb691b741b2edbbcccf4e5f857b0ff3380fbf2210dea194aab5a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.13.4@sha256:5175cc326261743ec11b1ac1845b3556b0378ad951fc76fec41718068997f540"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.13.4@sha256:b7d352792aeaf58cbbfb5454ad8965bf935dff2a2a84907d12035770c6bb3dac"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.13.4@sha256:46b6c7046e76692ec39d3e5abd72f8049868433dfa731f63477f048f36742c49"
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
