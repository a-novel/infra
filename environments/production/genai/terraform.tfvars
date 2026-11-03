images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.8.7@sha256:9b6505f703c8c3bd86e5ab7110ba37c7065984b0b04875894e3c51416a095263"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.8.7@sha256:0c6cf57cdfe7d8ff2f1d07cabdcb11269707946997aecd393f9b2ef85167a8a6"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.8.7@sha256:dccb7ec55fe0af431f9d4279427f58b02fd74ddea3ff5c946dd56ed0eb54b8b1"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.8.7@sha256:a595c733ce99ab52fce95cc60af503c76555b3a8cc7d2d8739ad9508693ba9da"
}

secret_versions = {
  openai-api-key = 1
}
