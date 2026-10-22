images = {
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.6.1@sha256:e0d758937c416694df291630853c9d5cf34ee2c4af95960445ac3694b4e0ce7b"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.6.1@sha256:16dd4ac6f099a4e896807819dd75e22a8c4d7970f06f7442a21b9e4b69af984e"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.6.1@sha256:3ae7eeebdc7f4abbd86b6ed038b97f342ec9ed7381dd49bc8b2a6e23f75d19ba"
}

secret_versions = {
  app-password   = 1
  openai-api-key = 1
}

alert_email = "geoffroy.vincent@agorastoryverse.com"
