images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.9.0@sha256:119b0d930dd05dafaaa3297d2ed3879ad8d09c49c620cc99b1935c7e51b7c301"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.9.0@sha256:f56a0ad6c298312e9de5496ce34a45d79bee1fd4905ebfaccffa383e9146e03f"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.9.0@sha256:481584cc33c16ebb098cce8a98816edc165bda1d4df0356f7ac80acbfb9083a6"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.9.0@sha256:eab35ad899bece4cdfdfa7551bfb3bdd7cf98c8ed33459d464e0bb1b883c4b0b"
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
