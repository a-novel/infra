images = {
  database    = "ghcr.io/a-novel/service-authentication/database:v2.21.0@sha256:cce2b62f9486ddbf490e142525c444777782593845b1c2a6ab4ddab06eb94846"
  maintenance = "ghcr.io/a-novel/service-authentication/jobs/maintenance:v2.21.0@sha256:e6b4b82b79a46bfdb46016dbb8c2ad74682284df288de6236dae9e9366b28bf2"
  migrations  = "ghcr.io/a-novel/service-authentication/jobs/migrations:v2.21.0@sha256:ffef930cdfd10137e2a8abae5e4c158a106c28f1e9bbba5f3539955d14c7b341"
  rest        = "ghcr.io/a-novel/service-authentication/rest:v2.21.0@sha256:dadef660adae593c7e50975bce65900ce04efca39549a6f28f8278da97361356"
}

smtp = {
  host         = "smtp-relay.gmail.com"
  sender_email = "no-reply@agorastoryverse.com"
  sender_name  = "Agora"
}
