images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.11.1@sha256:cbe7de0770951c90041857e59d3775f1b1ea86fa2b69b7858350017e083dc645"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.11.1@sha256:1255f6f35b7c73a3c8e244f09669c1830b8cb1616615a2b6105f7fe5b16b1f8e"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.11.1@sha256:45cbe096102a2018d1995b30f64fe1d9eff8ad3be7aa296aa7d1ecdcbc18a34b"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.11.1@sha256:4bb181a8c00f2d3ba6bdabf6ec92cf8b81c3a2e5d2cd5ba50ec6e874dba322f4"
}

secret_versions = {
  openai-api-key = 1
}
