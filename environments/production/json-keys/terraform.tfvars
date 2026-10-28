images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.13.10@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.13.10@sha256:30df698ad643886f231dfdfd821e7731a19d53e3530c61a350c7d29f01f0a770"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.13.10@sha256:4f0de361822b00715b20e0b346fe41710a0491fb263e6129180b1617fcfb017f"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.13.10@sha256:cbbeafcbfedafd6e554aa471efad65c2192c908eeaf78e209e488952b6fd4fee"
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
