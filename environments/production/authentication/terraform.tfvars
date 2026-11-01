images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.23.1@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.23.1@sha256:dea60b121011ee30b7728a42450f13b49cb766dc3a65f61e7fc8238c95b76ba5"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.23.1@sha256:9813febf01e7f0f7faf469ff81dfc0f073c6ad925bb94428d4c27d8f8e1f952a"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.23.1@sha256:418bcdbe82541bb98d3d9348e6588c4ffd3392f6cf4e96053bc1ffb59be124c4"
}

smtp = {
  host         = "smtp-relay.gmail.com"
  sender_email = "no-reply@agorastoryverse.com"
  sender_name  = "Agora"
}
