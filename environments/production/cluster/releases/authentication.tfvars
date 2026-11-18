images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.28.0@sha256:6e80692327dbdad03bd98de84429ec47163b6eab1cc0c4e53512392f942d655c"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.28.0@sha256:38473b1bfd0501f7ca6a308dcb21472713e3d16fdbc9520a282e3f4714711b48"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.28.0@sha256:d2f178f22ccf7130fb1cfbd73346aab68f656a41b5d2bfda675e821310beb510"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.28.0@sha256:8f002e4ed024b328edefcd6e56c04977d08319b5eb538fa38be2e10eaccca63a"
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
