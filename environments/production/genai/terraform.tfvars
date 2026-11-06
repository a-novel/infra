images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.10.1@sha256:9b6505f703c8c3bd86e5ab7110ba37c7065984b0b04875894e3c51416a095263"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.10.1@sha256:3f7303279049f6621cd70825fa2e085340ee248c384c3487f592e7c7cdcbb619"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.10.1@sha256:7ad2ec66770ea4f422f5fac742e10de013b574c16cc1f60485539c42b1d8e4e9"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.10.1@sha256:ca0aae0e47f0b0af6f0477a01a5e82b87b27d91010f6cbfe02bd90660392c2ef"
}

secret_versions = {
  openai-api-key = 1
}
