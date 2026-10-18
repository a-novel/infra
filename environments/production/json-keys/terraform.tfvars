images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.10.4@sha256:392e831c21e44cca0a75ed0d10f241002ae56323e22f8569a086722f96434d0b"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.10.4@sha256:28d841e18f50583f34259e23cb6145b166fb64be7b15fb1af8afb013ef9add12"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.10.4@sha256:6042022d4338d50ab1d458ffb7e5ae19021b9efc3f8a1947447aa944319f0b42"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.10.4@sha256:6499756e88cbefe1fea25037f292ccde3a0e4da1b878a3b27841b9c7bf091077"
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
