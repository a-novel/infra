images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.8.10@sha256:9b6505f703c8c3bd86e5ab7110ba37c7065984b0b04875894e3c51416a095263"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.8.10@sha256:7326da0d01c68c69efb73c4e2695129bfb35218b720d592516b98412a8147ba7"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.8.10@sha256:995fc65c63ba20265c64acd216b635314455593ca39ad996cb982f2665c61d66"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.8.10@sha256:d5a5d8cfa5db7fc326261b566400f4b463682d6c03595c5883aefa58b29a33db"
}

secret_versions = {
  openai-api-key = 1
}
