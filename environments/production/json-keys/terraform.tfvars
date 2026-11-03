images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.15.2@sha256:06457d216da6416e58262893731c6caf4382d74e89baa13aa79eaffd629c771c"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.15.2@sha256:ddc9cb884a2d84de072049ec0143044186e629aed5d814d61d22e84502ab441d"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.15.2@sha256:c68af5ae62955cc88c20fe9e5fe5f82e20f22a4694dbba9f9b23a90d1c6c5aff"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.15.2@sha256:9c2a7768e8cf0637071f0ec232499982da992505ddb8a482550bd329ef32c709"
}

secret_versions = {
  app-master-key = 2
}
