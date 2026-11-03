images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.8.6@sha256:9b6505f703c8c3bd86e5ab7110ba37c7065984b0b04875894e3c51416a095263"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.8.6@sha256:170b2711a5eaa6f33b1a637ca603068e22217a4ecca2d574deee51113cf19cee"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.8.6@sha256:bc7ae7fe3b3ac8bd70aeb2fbb4ad64fd23173468b0f46f2173451b83bfbf66d4"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.8.6@sha256:8f9d2c04677d26436d0704d3603a1b269826b88a58361cc943d1b4d8f62b8d50"
}

secret_versions = {
  openai-api-key = 1
}
