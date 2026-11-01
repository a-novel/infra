images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.14.2@sha256:a7fd1aa7ba4476c6775e391fd632e0e292ca0667a25bec07a0cc3fab57afad3a"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.14.2@sha256:3c7110a49719c1e1b18b1e9ac13c540e9e4d7b2cf64a156172c7eb04c73bf9d2"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.14.2@sha256:35297195666b725ad8f97c8fdef30257047fe87ddda11f888814a8ef28750901"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.14.2@sha256:b4c76dc38f700426caf5eba42e376bb8056e219edfcd080da86e4f6aa5039a38"
}

secret_versions = {
  app-master-key = 2
}
