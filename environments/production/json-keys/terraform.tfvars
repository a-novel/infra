images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.15.7@sha256:06457d216da6416e58262893731c6caf4382d74e89baa13aa79eaffd629c771c"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.15.7@sha256:a3d3bdde1ede68166831fe79b793a519c728db9bf7f8e5cc032d64fb9e163207"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.15.7@sha256:848da220a85c83036205d98e23eb8ce7f32e7b59ed502f87f49c1a094cc9993e"
  rest       = "ghcr.io/a-novel/service-json-keys/rest:v2.15.7@sha256:e93412c2570837c87cd39fff15589ce25abad11b89268213d680aabc44bef4a1"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.15.7@sha256:6a5e1082fa2dc1212ca269048613743a374365da2816d649f1f56cd1a073f1c5"
}

secret_versions = {
  app-master-key = 2
}
