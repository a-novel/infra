images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.25.2@sha256:e49463997f86041d1e146c6060cc19ab37992ea7ef929627584db6ff16832ffa"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.25.2@sha256:644e3989c55661e345983e9ff783ec38aa0a7c6d3450b358cfeae29aaea96a0c"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.25.2@sha256:68d709d78b994ea972594a9130d0a06099373882ab737dc978ea27a8e8e958f5"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.25.2@sha256:2a9dcb08662cb9da3398a19135653a936474a690d52f4c819121044beff06dff"
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
