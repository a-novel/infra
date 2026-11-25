images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.29.0@sha256:3d78b68381b8313a76742ddde51eb8d21b17e7bd2f931c6261cf87f450f9a284"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.29.0@sha256:df8b4e3ba49ebe1d312f0461a87b55a512cc13048795279669980c8863e146ed"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.29.0@sha256:e59f2a8e5b2f15f65db375b690232fd6cda349403c9f87f49f24625e3c9cb18f"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.29.0@sha256:87afa493a5760370e0a53db207ccdd2614110cdc8120128a06bb2f38879578fc"
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
