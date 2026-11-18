images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.17.0@sha256:02c80da1ffbc8f9e91225c5871b031a086eeb231e27877db19deed036bf4c7d0"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.17.0@sha256:c7cb91d5a1b7a5e641c8c67887cc57a3e7458fe32f0923ba6e026dc732250e6f"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.17.0@sha256:25519a277556a3b82b4d0a062ae5241352857463cce63d367fb6ea6ba2109737"
  rest       = "ghcr.io/a-novel/service-json-keys/rest:v2.17.0@sha256:9b1b786f57746a08690931036ae918387c875875670a619e9025492c65d55760"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.17.0@sha256:24ad222a63fbe51e5b91da2b0f55e379bcfe813bd0744e57dca6721c02c7738f"
}

secret_versions = {
  app-master-key = 2
}
