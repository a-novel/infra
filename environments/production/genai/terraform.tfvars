images = {
  database   = "ghcr.io/a-novel/service-genai/database:v0.8.8@sha256:9b6505f703c8c3bd86e5ab7110ba37c7065984b0b04875894e3c51416a095263"
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.8.8@sha256:e9eb72b6b6918fa57b72232f8032e5ccefddd777e614d48bffde444eba1f21b8"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.8.8@sha256:e6e9bb2c554d095557451ec3cc459658428508665b7120921271fb0d293df1c7"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.8.8@sha256:e6af1df15ff845a90ebaf30aa70978e649de7cdb1cdc20b51a4c8a3b4b1d56d0"
}

secret_versions = {
  openai-api-key = 1
}
