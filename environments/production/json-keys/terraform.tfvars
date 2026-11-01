images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.15.0@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.15.0@sha256:18da092cf8657a145154d701c5b3322b73fe2a63e72b0974e36c5c724b5f61de"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.15.0@sha256:965abf4a138e1bdcaa93736d4769009d5f2765e579b13e7f7eb0472ed9e225ae"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.15.0@sha256:2a908cf3cffeb66ff7b63f436fe006f85cfd1dd454db208349e98fe1059ad94b"
}

secret_versions = {
  app-master-key = 2
}
