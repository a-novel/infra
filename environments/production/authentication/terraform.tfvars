images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.24.0@sha256:e49463997f86041d1e146c6060cc19ab37992ea7ef929627584db6ff16832ffa"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.24.0@sha256:7a63b35abf989caff26bbdaae5c525ae802e33ee77a373a08cd724543d5930de"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.24.0@sha256:424b68e156bcf2c37f8ba928fa52cf005569702b27f5b9d92c46606265e8ea1b"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.24.0@sha256:b5ed5ae51fa9145e0d96fac7f3b948c1ad48a951856ac2c85092865112e03a5e"
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
