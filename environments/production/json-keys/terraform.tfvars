images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.10.2@sha256:392e831c21e44cca0a75ed0d10f241002ae56323e22f8569a086722f96434d0b"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.10.2@sha256:94cd6dae5183a4cac3f1d40b4c536f8b39373e672ab5ac557ee75fe680872056"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.10.2@sha256:64bf4ff494c63098459ba609873934b67b72f30e1cdaa588d5fe51082c54e9ee"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.10.2@sha256:188216970d9c837d4f60c187078e902a26751baf96dfa1fb54318e8c51be317a"
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
