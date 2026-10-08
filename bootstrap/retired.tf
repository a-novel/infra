# Retirements for #666. Delete this file once they have applied.

# A for_each instance inherits its resource's prevent_destroy. Moving it to an
# address outside the configuration destroys only that instance.
moved {
  from = google_service_account.automation["recovery"]
  to   = google_service_account.retired_recovery
}

moved {
  from = google_iam_workload_identity_pool_provider.github["recovery"]
  to   = google_iam_workload_identity_pool_provider.retired_recovery
}

removed {
  from = google_service_account.retired_recovery
  lifecycle {
    destroy = true
  }
}

removed {
  from = google_iam_workload_identity_pool_provider.retired_recovery
  lifecycle {
    destroy = true
  }
}

# The deploy identity needs these grants to delete the receipts bucket, so they
# are forgotten rather than revoked. They disappear with the bucket.
moved {
  from = google_storage_bucket_iam_member.foundation_admin["receipts"]
  to   = google_storage_bucket_iam_member.retired_receipts_foundation
}

moved {
  from = google_storage_bucket_iam_member.operator_admin["user:geoffroy.vincent@agorastoryverse.com:receipts"]
  to   = google_storage_bucket_iam_member.retired_receipts_operator
}

removed {
  from = google_storage_bucket_iam_member.retired_receipts_foundation
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_storage_bucket_iam_member.retired_receipts_operator
  lifecycle {
    destroy = false
  }
}
