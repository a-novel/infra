images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.13.0@sha256:8778711f5c9beb691b741b2edbbcccf4e5f857b0ff3380fbf2210dea194aab5a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.13.0@sha256:83e1e30fb4d0ca89177f8cbe16c71cf05bbc69d1d562b72f15e18288542ffb7b"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.13.0@sha256:1834a94154e1436d959573baf88ddc7045158ad9e0fc317353ec4a9677c53732"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.13.0@sha256:e0426363654896d98465d066903739b2fb08efa829d04a72d2e57d88aa7c8115"
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
