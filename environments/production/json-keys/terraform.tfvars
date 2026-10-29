images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.14.0@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.14.0@sha256:9a12fe4f000722f1718e4c2ee7043d02aff578a091903bcffc9845ba3083aaa5"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.14.0@sha256:d6f3a961ca62c076769da8643a3597f236ef3a82c54590c96566cd46ee66896c"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.14.0@sha256:9ea474d672092c3af7f08a1f532771c9b96d14ea7ec86dccc1ab6b03065fa5dc"
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
