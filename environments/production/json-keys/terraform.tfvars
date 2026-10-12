images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.10.0@sha256:119b0d930dd05dafaaa3297d2ed3879ad8d09c49c620cc99b1935c7e51b7c301"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.10.0@sha256:061d15b8d6564f51b2e8bf51e0024cf123e6a346dea2cdc9aa47cd3240ffbb1f"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.10.0@sha256:aa59b03e2d0d3ff75876ae1385df59006980803ba2fb10be67513b348a84899e"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.10.0@sha256:3f4e66855d71b5ad3e74216b1c222bd0f1c5e1ea342a5640fa4d5ff37cd64e6c"
}

secret_versions = {
  postgres-password = 2
  app-master-key    = 2
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
