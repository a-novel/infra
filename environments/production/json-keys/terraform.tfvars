images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.15.5@sha256:06457d216da6416e58262893731c6caf4382d74e89baa13aa79eaffd629c771c"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.15.5@sha256:389547f8eca6d3bb748aa24abc715020ca03621f8b50bfee94eda266c1022f13"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.15.5@sha256:ac2d09d946586b9c5e53a8387bb6e8f265093dab1637a0c0ab98b77756595699"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.15.5@sha256:2b06b8ce3a6ed163e1fa258e0d9f06e0941b833ca831cfbd67cc206e89904cfc"
}

secret_versions = {
  app-master-key = 2
}
