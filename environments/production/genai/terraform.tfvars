images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.11.0@sha256:cbe7de0770951c90041857e59d3775f1b1ea86fa2b69b7858350017e083dc645"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.11.0@sha256:b96cb4d2d87e9577b53b5c30f80c7428c56d22915693b70969a09f48fc93b77c"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.11.0@sha256:592ce1f82e4196ce47f5eed23b26665275aa138be55a28085623b436e6d067d0"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.11.0@sha256:4643ff435ab96ba2e87aced45eb7127cc95d9b7e724cb7dec9764c3a5e4eb3c4"
}

secret_versions = {
  openai-api-key = 1
}
