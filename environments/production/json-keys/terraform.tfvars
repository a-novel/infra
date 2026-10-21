images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.12.0@sha256:f1072d3e67f7c333eb84c35b1be9bdad6bb3beae362a6d808b39f2f2ec073c11"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.12.0@sha256:e574410caf3c6670fd8a410ec53f16420c5cdc10e89cdf1fb0d2565d8c482fb2"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.12.0@sha256:5057935c8fcf55e00acee82fcab1a9d876491bb92b20cc60c5fc3e61e62b690d"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.12.0@sha256:5fd92eb11c69c79bc73a89cb87d7de27f11f31551e60036403f34f33fb8ae44c"
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
