images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.25.1@sha256:e49463997f86041d1e146c6060cc19ab37992ea7ef929627584db6ff16832ffa"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.25.1@sha256:f34d49e5b6c4be47449c3f82320c12ede8a9b87e52749e44ad3e9c0ddfaf2282"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.25.1@sha256:6d49ba4341b6b560828f36695c9ec7f4303604494456c74d24d7b6399750b967"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.25.1@sha256:fe41bee5d6178931cc86a9542d5a77eff21ecbf223c06d7a71e1d1ff0fef8f3c"
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
