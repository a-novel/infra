images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.18.0@sha256:f995fbc71e3eddfe7e247b7aa393198c0c7c75da5e4e77df2d30125e8fa0dd07"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.18.0@sha256:47568a935408306d0946ca05fae8095e21b9e5689ff44277ad376ad54a87da52"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.18.0@sha256:1ba290a161bc5c34c4b41821bfee24304ce74d5945c77e1a3862e1e96e44a851"
  rest       = "ghcr.io/a-novel/service-json-keys/rest:v2.18.0@sha256:38bc1432cc54dd40e0ab28a02d7430f3596787d2a57e8f8c0148e917f10ef8f1"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.18.0@sha256:ad2ec5f6342b5e780b2fdddaf0d3461d5e82cc257011f6fad5d6f6bd2e16f0ed"
}

secret_versions = {
  app-master-key = 2
}
