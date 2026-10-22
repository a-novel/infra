images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.12.2@sha256:a421bf1d7f00194505779efaa1f9cf643d57f11b346ba3d0f349bcf829fe11eb"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.12.2@sha256:3eaed0ee887af789bb9fdd4730ee68c4441f328812cd2441172a2f2c07c07c00"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.12.2@sha256:b0befd0841d495eb678c005439b69ccc5abbe20c39cd8bc20af08766a52a9a03"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.12.2@sha256:1960bb5f95218060aa2777c3985298e02231f6d2388c87dd3087a4c9be51e15c"
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
