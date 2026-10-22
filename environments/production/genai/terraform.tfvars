images = {
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.6.0@sha256:2cc5ecdad1966167a0b0ff295cb59344eaa6d164e69d5bad78019d803e5b9e30"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.6.0@sha256:38344cdaf66a8803a57510f9dbd5ff560aea1ee618c3dd7fc77f94364cd97a17"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.6.0@sha256:351c2a1303f4a1ab4f4df0b2387a95b9a4aa6b7ac79795888613b7ba69ddc903"
}

secret_versions = {
  app-password   = 1
  openai-api-key = 1
}

alert_email = "geoffroy.vincent@agorastoryverse.com"
