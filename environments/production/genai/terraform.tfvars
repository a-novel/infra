images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.9.0@sha256:9b6505f703c8c3bd86e5ab7110ba37c7065984b0b04875894e3c51416a095263"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.9.0@sha256:0006039dd3b3d638994f837569d7d4029b53f5049e36891d4990ee7d9699afe8"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.9.0@sha256:bd5b6f73fce7330f16041f41e66b3909d84470b6f3d6eebc8127df264ed4a455"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.9.0@sha256:7bc8870eba30f4e472ab4c16ae226ec89cdc686b085e2d3682a5f45f2ab2bd8d"
}

secret_versions = {
  openai-api-key = 1
}
