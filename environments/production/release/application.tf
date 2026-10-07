# Foundation imports these objects only after this state relinquishes ownership.
removed {
  from = google_cloud_scheduler_job.json_keys_rotation
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_tags_location_tag_binding.application
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_tags_location_tag_binding.json_keys
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_tags_location_tag_binding.json_keys_smoke
  lifecycle {
    destroy = false
  }
}
