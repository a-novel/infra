images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.15.8@sha256:59cc97cda142289a494eadac04a48da83243ccb4a4975f07e08361627dfb9ae2"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.15.8@sha256:697dd1a0c1954e3ed2de249cef8f0d7ab96604f780f7c6a881b995dd106d1c92"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.15.8@sha256:9dbe2d17818232643f03a04c702fd52bf19e2b4d7261018942fdd087a67d532d"
  rest       = "ghcr.io/a-novel/service-json-keys/rest:v2.15.8@sha256:c4860fc45c1823816a1fb8088d33c73971ab9cc70fe1ee4d272241e72d59d1b8"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.15.8@sha256:d25493fb736442b0c0aaeed6af00ff41cd027041e68636f8fd3138541c56eb9a"
}

secret_versions = {
  app-master-key = 2
}
