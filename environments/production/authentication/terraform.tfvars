images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.21.1@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.21.1@sha256:6b8ef661c5876557f4422ed4c217f96956467fe3b8f3d8b1c501f00dff916742"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.21.1@sha256:cd1b406ae64b10e373eb0640ee9b78d2327611208730a633b6ff9a8678502991"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.21.1@sha256:32e2b535f8e7a08b04ebd7144df1cab499d83651ff6ac92b9a8b4fab236c4f3b"
}

smtp = {
  host         = "smtp-relay.gmail.com"
  sender_email = "no-reply@agorastoryverse.com"
  sender_name  = "Agora"
}
