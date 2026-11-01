images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.20.1@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.20.1@sha256:4f1e8a028b98ac1541a93e4ac6961e12472ba4925217f480b87a8f7dfd80f5ce"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.20.1@sha256:4d2cc3216caab5842937578f1f5a04e04330e2ca18b56993789215f42021530a"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.20.1@sha256:9a657d98096c83b01ecbbe8d087ce6af60ef2e03d94f9739e5eec1037a9aea9f"
}

smtp = {
  host         = "smtp-relay.gmail.com"
  sender_email = "no-reply@agorastoryverse.com"
  sender_name  = "Agora"
}
