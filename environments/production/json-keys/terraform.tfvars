images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.13.8@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.13.8@sha256:26ae9758b606e7e1114dbce070281c63ce2a4fabe690d21084267137c80ddac6"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.13.8@sha256:c56e58691114fa6fc98c8ef297aee4f814b1106969177a9bfa2fcbb32fca8f83"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.13.8@sha256:0da8b24a02af2f2e1e47d10ce0868735cac8e3227ccd0707ecdd2d1e7d7b555c"
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
