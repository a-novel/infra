images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.8.4@sha256:369e9a0be29523f014eae389a2a638454af6f24b0844286795bac3969c1667e3"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.8.4@sha256:4085fd429dedec498de34cbf6faf1c29b5b3e997ec20b7061097dc154ea92067"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.8.4@sha256:cb94f7ad48b962ebba9796763847b0faaa0f0af246824382852b0ecbd6b34716"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.8.4@sha256:3d5a1a37ef9318e949f9b3bf4aeebadda8704d66eefe4e8e80437d980bda7863"
}

secret_versions = {
  openai-api-key = 1
}
