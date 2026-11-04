images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.8.9@sha256:9b6505f703c8c3bd86e5ab7110ba37c7065984b0b04875894e3c51416a095263"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.8.9@sha256:0b8229c80a6add9c53e56c73e4624948ee7dcd9c698694f6070c8cbfd1277ed0"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.8.9@sha256:831e1c9770789ec812b2105167284951541102ee01f66db851644c820707c7da"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.8.9@sha256:7920b8f086c95135dbd549d90c9f90026525310a129de1a9f8e0c20b92b4f7dc"
}

secret_versions = {
  openai-api-key = 1
}
