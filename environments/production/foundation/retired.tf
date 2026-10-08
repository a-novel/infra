# Retirements for #666. Delete this file once they have applied.

# A for_each instance inherits its resource's prevent_destroy. Moving it to an
# address outside the configuration destroys only that instance.
moved {
  from = google_service_account.runtime["authentication"]
  to   = google_service_account.retired_authentication
}

moved {
  from = google_service_account.runtime["json_keys"]
  to   = google_service_account.retired_json_keys
}

moved {
  from = google_tags_tag_value.cloud_run_invocation["recovery"]
  to   = google_tags_tag_value.retired_recovery
}

removed {
  from = google_service_account.retired_authentication
  lifecycle {
    destroy = true
  }
}

removed {
  from = google_service_account.retired_json_keys
  lifecycle {
    destroy = true
  }
}

removed {
  from = google_tags_tag_value.retired_recovery
  lifecycle {
    destroy = true
  }
}
