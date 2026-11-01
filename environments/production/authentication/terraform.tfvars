images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.22.0@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.22.0@sha256:94e9aed1e8d70d0261904984a3a1b0371eca99b43cb593759eba57e528c791db"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.22.0@sha256:a480ca17e781dbb9d62578c22fbfbea23768250945e9bffe5a4d088420d71576"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.22.0@sha256:e13c59536e1b6153b97e41f2c01354944fdec1cb7b1bb485add9577eb137695d"
}

smtp = {
  host         = "smtp-relay.gmail.com"
  sender_email = "no-reply@agorastoryverse.com"
  sender_name  = "Agora"
}
