images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.25.0@sha256:e49463997f86041d1e146c6060cc19ab37992ea7ef929627584db6ff16832ffa"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.25.0@sha256:761a62cff106c3a0c9115746706d4cbf4075bfc2c2513ddca99bba92c7d1a454"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.25.0@sha256:2f6efbccd00dbecfa0d2e7bba92b4c422074c63709fd65fc956860bc7862843f"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.25.0@sha256:387799da7e11a0e0e52add25315f5ba05e4d5de3ea74d2ac94f1bd1267af0002"
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
