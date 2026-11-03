images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.15.3@sha256:06457d216da6416e58262893731c6caf4382d74e89baa13aa79eaffd629c771c"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.15.3@sha256:9be8eef67b3dea0664273f0925d2ee72879e029f28beab0746920865d9131f1a"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.15.3@sha256:c0ac1f1a6c58fa8c9c01d0fef8e29967441ad114b13d85e7d14ad1f40109c915"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.15.3@sha256:367a8967b2d9e72e9751f52e89eda4593cb22b1e2b39360aede1182c37145fbb"
}

secret_versions = {
  app-master-key = 2
}
