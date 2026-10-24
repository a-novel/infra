images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.12.3@sha256:8778711f5c9beb691b741b2edbbcccf4e5f857b0ff3380fbf2210dea194aab5a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.12.3@sha256:ec9672a8b8584c25d5e2519ffedcc72d78b42c0c9d660e4202492ca7e198bbb6"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.12.3@sha256:17eb51a95a74e3e34eea019a87fa9f3bc9461dc2507b96341c5e98a3d6d801b3"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.12.3@sha256:e8063bd6621da98ddf5dc6b889811b196cc945b6e07a639fb64f6a232816c00c"
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
