images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.13.7@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.13.7@sha256:b4119dbd32dc7fa00249826cf78df956a0ab78bb06abea2456532df50586a3d4"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.13.7@sha256:56d61902756b065130417eba97a1f7eba34c40d3e1e15d84f3dbc3edf9d512ec"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.13.7@sha256:485f11f05e433341ba96c2330e7b697df3397b25a4f2439c6808ffaa9da66a7b"
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
