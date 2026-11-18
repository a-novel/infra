images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.27.0@sha256:6e80692327dbdad03bd98de84429ec47163b6eab1cc0c4e53512392f942d655c"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.27.0@sha256:10eb05d3cd624e63ce1dd9353bbec822cea8a7b72a721b766f6cef472f159628"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.27.0@sha256:2d4947e5691959f47824a375d384db06e6b68bac8c4d7533e5f2c2aa872018b4"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.27.0@sha256:1cfcbb6740dbe02d06c99a1808609749a211170d4de6fe74bc48b65cee95e705"
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
