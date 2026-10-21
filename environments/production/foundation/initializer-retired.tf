# The maintenance job replaced the one-time initializer (a-novel/.github#331), and
# a-novel/infra#964 deleted its grants and unlocked its account. Moving the account out of the
# protected for_each lets the removed block destroy it, while prevent_destroy guards every other
# identity.
moved {
  from = google_service_account.runtime["authentication_initializer"]
  to   = google_service_account.retired["authentication_initializer"]
}

removed {
  from = google_service_account.retired

  lifecycle {
    destroy = true
  }
}
