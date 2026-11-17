images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.26.0@sha256:f5fa56caa72a3e1ffcd53d84abe364447647d03f6904bdf0d1e84dadb3c51dbb"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.26.0@sha256:0ebf9a7dc7e2122e45075122f79d4e4e953e38f76ca2dc2490aeeae617ca5f76"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.26.0@sha256:7c83cd77b894b155d0bdd6f12f994d643b64036e06e12ac612bc8426f65f17a4"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.26.0@sha256:6378965e9bd18ae54dd7e5172284560ff50b88d6c504540aef0146ac59035afa"
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
