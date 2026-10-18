# The database owner passwords have had no reader since a-novel/infra#925, and the owner role
# has no password. a-novel/infra#926 unlocked them. Moving them out of the protected for_each
# lets the removed block destroy them, while prevent_destroy guards every other secret.
moved {
  from = google_secret_manager_secret.application["production-authentication-postgres-password"]
  to   = google_secret_manager_secret.retired["production-authentication-postgres-password"]
}

moved {
  from = google_secret_manager_secret.application["production-json-keys-postgres-password"]
  to   = google_secret_manager_secret.retired["production-json-keys-postgres-password"]
}

moved {
  from = google_secret_manager_secret.application["production-genai-postgres-password"]
  to   = google_secret_manager_secret.retired["production-genai-postgres-password"]
}

removed {
  from = google_secret_manager_secret.retired

  lifecycle {
    destroy = true
  }
}
