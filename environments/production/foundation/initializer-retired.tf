# The maintenance job replaced the one-time initializer (a-novel/.github#331), so nothing carries
# the initializer invocation tag. Moving its value out of the protected for_each lets the removed
# block destroy it, while prevent_destroy guards every other value.
moved {
  from = google_tags_tag_value.cloud_run_invocation["initializer"]
  to   = google_tags_tag_value.retired["initializer"]
}

removed {
  from = google_tags_tag_value.retired

  lifecycle {
    destroy = true
  }
}
