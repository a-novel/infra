images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.13.0@sha256:9aafca234ebd25ca3db0f29546264d6f748e1f3b2ab500006364c6af8c6292d9"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.13.0@sha256:9e564c8ac4d730e3033faf4d65487c1eb74d05d97d4be25fe89cf77305c5e147"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.13.0@sha256:8555bdadd2128e686ebdbc6496831a28a723aa42c380d3234e6ee483331e13e0"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.13.0@sha256:bf7391310f0f7700b87324dadbcd72465bd951badd3988afe68db237481c9f46"
}

secret_versions = {
  openai-api-key = 1
}
