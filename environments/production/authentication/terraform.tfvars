images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.25.3@sha256:e49463997f86041d1e146c6060cc19ab37992ea7ef929627584db6ff16832ffa"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.25.3@sha256:3b3392cff2c3196d58a1a851df9cd3ad9362779cdc7d4658ce5ab727e188bdbc"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.25.3@sha256:9e70eabf0fad9d3fb7bea5e3b87c4b14bf49fc1434d1207ca2d6fa9bf721f303"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.25.3@sha256:4de023af0aa54f44367406383381b291edb401cc4267b280e8083a66dd83e9b4"
}

smtp = {
  host         = "smtp-relay.gmail.com"
  sender_email = "no-reply@agorastoryverse.com"
  sender_name  = "Agora"
}

secret_versions = {
  waitlist-secret = 1
}

waitlist_url = "https://script.google.com/macros/s/AKfycbynt0DbObOkLBwIJh4cyf8ZjXTXPG55wdhp8bs6JEFkj8T100xcBaT8tzavOXOgoSpO/exec"
