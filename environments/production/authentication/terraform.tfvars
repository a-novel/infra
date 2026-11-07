images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.25.4@sha256:eacb92cda967cca5fd86c5b13d652cb4b6de3ba66794c7ceb7428b62970831e1"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.25.4@sha256:bfaf3cdb0703d844ca4603dc05231d40e7cd94523b6eb5012262ab536a0d324a"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.25.4@sha256:9f1687aeaafb232256e86c0f2aedf453b29ef8a20036a5a1e74fcd4b9d600321"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.25.4@sha256:8401d087e8b417412c538003eafe148044f1193cf6fd671ebf74cde9f947a0f2"
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
