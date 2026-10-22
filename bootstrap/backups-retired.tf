# The logical-backup bucket is empty and retired (a-novel/infra#638). The deploy identity deletes it
# through this grant, so the grant is forgotten, not revoked first, and goes with the bucket.
moved {
  from = google_storage_bucket_iam_member.foundation_admin["backups"]
  to   = google_storage_bucket_iam_member.retired["foundation-backups"]
}

removed {
  from = google_storage_bucket_iam_member.retired

  lifecycle {
    destroy = false
  }
}
