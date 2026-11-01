images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.23.0@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.23.0@sha256:6d516466f00c3e5f000c5ae0b5aea47641d512c4eb7bd47c69b05fdf7b4740bc"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.23.0@sha256:e7a8acadcc20d07b69ab1dcc67de4e2fc69a41c459c75724231798d679580e8b"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.23.0@sha256:48a64e20f536a05c1494eba09175ccbbe3468b31adc4e894c6953a9e5d824faa"
}

smtp = {
  host         = "smtp-relay.gmail.com"
  sender_email = "no-reply@agorastoryverse.com"
  sender_name  = "Agora"
}
