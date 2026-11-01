images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.8.2@sha256:369e9a0be29523f014eae389a2a638454af6f24b0844286795bac3969c1667e3"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.8.2@sha256:675670683aaed8d01244630ab7aaad64fd341677b4ab45ec6fb7cff3b45b769a"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.8.2@sha256:c6895d49275eb2817a70e00da028063cec31cf2255fd7048c978744faaa513e4"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.8.2@sha256:d1e62686d239a289b588888a1e6dd47e0652125675e9b3b5ed23ae56c9da5191"
}

secret_versions = {
  openai-api-key = 1
}
