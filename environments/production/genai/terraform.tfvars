images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.8.3@sha256:369e9a0be29523f014eae389a2a638454af6f24b0844286795bac3969c1667e3"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.8.3@sha256:0b3604857fa2b32865b5bb30dda94563e4c6ab47121425bd7d7c9ea905f9a20d"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.8.3@sha256:57f03ea307fcb59c332bcccb0c1c624e8306744b49a06d3af780fb70496f03ad"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.8.3@sha256:210f84d32af3721236c6b95b38dc1d7c94c5286814badeef0cec2725cc9ba504"
}

secret_versions = {
  openai-api-key = 1
}
