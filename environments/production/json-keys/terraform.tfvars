images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.10.3@sha256:392e831c21e44cca0a75ed0d10f241002ae56323e22f8569a086722f96434d0b"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.10.3@sha256:3168d79b505c7ade911120d45b86a79d715f6cf1bb9eafe2ccbbc4cc126f4f20"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.10.3@sha256:27de4e3f8a68c6c162f9d5a58e47c7dc109e96b455adbe99733ca0f7a94a9d3d"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.10.3@sha256:22720b8944f156b6f900910c841765c6ab9c75fe10ec0b7eae5dfcf45cf7d121"
}

secret_versions = {
  postgres-password = 2
  app-master-key    = 2
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
