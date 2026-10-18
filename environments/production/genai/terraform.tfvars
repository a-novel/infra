images = {
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.5.0@sha256:619545a3fd0eb22f3ef70fb5c927819355bf9ff9755cc83bfdb9a8358660c1a8"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.5.0@sha256:f5af5d12a188072da1e51ab51b5b2aef3c28be5941ed5b9dc48e0780d45bf453"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.5.0@sha256:279ca54fb7c4b277056d15c1d26dc1930e07b19b9a2cce21f9542f23c6c63a07"
}

secret_versions = {
  app-password   = 1
  openai-api-key = 1
}

alert_email = "geoffroy.vincent@agorastoryverse.com"
