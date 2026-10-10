images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.9.0@sha256:119b0d930dd05dafaaa3297d2ed3879ad8d09c49c620cc99b1935c7e51b7c301"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.8.0@sha256:84bb37c8dc9f8669b975fec8c6bb7636fb2e61b67f134246245f4727a4141b19"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.8.0@sha256:95dd4bb962d5345f171b718dcd888d6bc11e1856022d442a8a80be4a6bdc86f6"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.8.0@sha256:d7eb0811340b903a7d9a20b75911711f8d35b95687250792c167777be7aeac6c"
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
