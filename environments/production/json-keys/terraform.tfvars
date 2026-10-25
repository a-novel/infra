images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.13.1@sha256:8778711f5c9beb691b741b2edbbcccf4e5f857b0ff3380fbf2210dea194aab5a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.13.1@sha256:728b94df5c826514d0ea034a0e739770605cb475c6cd497bdec84d2196a5a64d"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.13.1@sha256:fbffe8819c894ec6359812cb025b53d2d45a2e0bfe9c64f675a4901b6ec81261"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.13.1@sha256:8f6a9468a58533ee84d2dc2567c53a731d753b51a2fd3935fa8204bbae5d3679"
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
