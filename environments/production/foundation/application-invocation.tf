# The Cloud Run workloads' invocation tags go with the workloads, which the service roots delete
# after foundation applies (a-novel/infra#1208). Deleting the bindings first would take away the
# tag-conditioned permission that deletion needs.
removed {
  from = google_tags_location_tag_binding.application

  lifecycle {
    destroy = false
  }
}
