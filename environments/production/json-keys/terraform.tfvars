images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.10.1@sha256:392e831c21e44cca0a75ed0d10f241002ae56323e22f8569a086722f96434d0b"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.10.1@sha256:72713033035f7a16342e35838d3eb80e86b7ce1521b0022ad5971db9c722d383"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.10.1@sha256:43bbde6528244d58a0cb32aa5066d601799c0365b0fc008b0c07a1501391578f"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.10.1@sha256:62f30d42c611631d33a045324a4f95f3bd2cba2c2dcbc2532dee179de06778d2"
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
