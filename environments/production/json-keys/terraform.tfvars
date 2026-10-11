images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.9.1@sha256:119b0d930dd05dafaaa3297d2ed3879ad8d09c49c620cc99b1935c7e51b7c301"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.9.1@sha256:108bcac7c8921b7fd9c9aed1c0caeea5b0091564e1e5b2d1c7a5d3d2aa0baa8a"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.9.1@sha256:8b5494cc711fcc5cab26c260a1f53aa1cdde3926512ff80262a60ba279fc16a0"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.9.1@sha256:20de27f2666620d97348a498206bdfd25bce113b72321010a50fa0ebf0193d24"
}

secret_versions = {
  postgres-password = 2
  app-master-key    = 2
}

backup_repository = {
  cos_image = "projects/cos-cloud/global/images/cos-129-19506-505-8"
  runtime = {
    credentials_image = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-json-keys-private-tooling/host-credentials@sha256:a5e264fc51c824c52fb6fd59b035e14e52fdc9f77e47b0375b352d8ad9bfd00d"
    client_name       = "agora-database.a-novel-production-prod"
    ca_version        = "1"
    identity_version  = "2"
  }
}

alert_email = "geoffroy.vincent@agorastoryverse.com"
