images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.23.2@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.23.2@sha256:0e49818ef779600842136f6b4d221722d379b8acf6088f4e8b794fb530528790"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.23.2@sha256:3f34d3f4d3ba2fe3640fce853718661ee6b38356ae9f57e15c1366f813c42e7b"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.23.2@sha256:ed7d064860327924f1616f6d75331083e4a8a30fc9047cd55529ae0cd0e3eab2"
}

smtp = {
  host         = "smtp-relay.gmail.com"
  sender_email = "no-reply@agorastoryverse.com"
  sender_name  = "Agora"
}
