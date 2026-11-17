images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.12.0@sha256:9aafca234ebd25ca3db0f29546264d6f748e1f3b2ab500006364c6af8c6292d9"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.12.0@sha256:ac3e1357fc9d41f008d9a6f1d99681b49b61122e8fc92afd0c7d8d14f40df76c"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.12.0@sha256:ff068d3e9120f72c98f20aaf186b602e43660f45695f935ff1b7b8bb09a8dbe6"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.12.0@sha256:bcca8b097e04d1e6d0f57edc0ef4dba7e9ae61f660b27e51363fe01d534cefe5"
}

secret_versions = {
  openai-api-key = 1
}
