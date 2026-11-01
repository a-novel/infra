images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.14.1@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.14.1@sha256:2f3d9afe9c813d178dca720a3552d3d32a3f2764f4d585d85bec0e0cef012ba9"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.14.1@sha256:4b7c9d3076e7abf014ccb3e8fe1f0f4f5c8153a5af5eb05985851d4aa9562b12"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.14.1@sha256:c0a59dfb76df228db7a6aa4effc9fb22abae650c7294fc8ee98d12d73e2e0244"
}

secret_versions = {
  app-master-key = 2
}
