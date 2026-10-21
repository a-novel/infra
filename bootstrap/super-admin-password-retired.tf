# The bootstrap administrator password has had no reader since a-novel/infra#964 retired the
# initializer, and a-novel/infra#969 unlocked it. Moving it out of the protected for_each lets the
# removed block destroy it, while prevent_destroy guards every other secret.
moved {
  from = google_secret_manager_secret.application["production-authentication-super-admin-password"]
  to   = google_secret_manager_secret.retired["production-authentication-super-admin-password"]
}

removed {
  from = google_secret_manager_secret.retired

  lifecycle {
    destroy = true
  }
}
