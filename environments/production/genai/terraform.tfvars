images = {
  grpc       = "ghcr.io/a-novel/service-genai/grpc:v0.7.0@sha256:572a587a693e4662798ab927b87d8361945d38a430353648e4414350613521ac"
  migrations = "ghcr.io/a-novel/service-genai/jobs/migrations:v0.7.0@sha256:5088c02199dc3ecaa3172aad9057bfe3e07f4f99ee849bea8ad50eca4a397411"
  sweep      = "ghcr.io/a-novel/service-genai/sweep:v0.7.0@sha256:788b99a8b2a54457f5d84ab2bddf356951f10ab82151183caf9dcfb4ddc0b748"
}

secret_versions = {
  app-password   = 1
  openai-api-key = 1
}

alert_email = "geoffroy.vincent@agorastoryverse.com"
