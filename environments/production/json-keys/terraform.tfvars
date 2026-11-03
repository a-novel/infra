images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.15.4@sha256:06457d216da6416e58262893731c6caf4382d74e89baa13aa79eaffd629c771c"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.15.4@sha256:a6738de5e0c0e90691a1f791047f72bd49026a2c8172840f377a944ca67f7523"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.15.4@sha256:480d8971aacf2734998eb5eb2d9a3c85983b2d3d04aea5e908c384b387594ab7"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.15.4@sha256:22e59b5edcb419f7eba07ec1a012aa2470907dbf9af6cf42fabcbb08b349d522"
}

secret_versions = {
  app-master-key = 2
}
