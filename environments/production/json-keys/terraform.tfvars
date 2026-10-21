images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.11.0@sha256:f1072d3e67f7c333eb84c35b1be9bdad6bb3beae362a6d808b39f2f2ec073c11"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.11.0@sha256:fcec46c3baddb95e43b3873ce864af7134adbfd5f7a6352e9da589caf5c0bb1b"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.11.0@sha256:ec10a9341e26e0f3245bd6631462453e073d88e993f2d956aebd52ded4341daf"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.11.0@sha256:e993dca5892c199e0fbe40fffc7d9ab7aa7eccfcd48c4036345f838075267ba5"
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
