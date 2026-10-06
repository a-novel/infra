moved {
  from = google_project_iam_custom_role.pgbackrest["writer"]
  to   = google_project_iam_custom_role.pgbackrest["json-keys:writer"]
}

moved {
  from = google_project_iam_custom_role.pgbackrest["recovery"]
  to   = google_project_iam_custom_role.pgbackrest["json-keys:recovery"]
}

moved {
  from = google_secret_manager_secret_iam_member.pgbackrest_tls["ca:agora-json-keys-database"]
  to   = google_secret_manager_secret_iam_member.pgbackrest_tls["json-keys:ca:agora-json-keys-database"]
}

moved {
  from = google_secret_manager_secret_iam_member.pgbackrest_tls["ca:agora-pgbr-json-keys"]
  to   = google_secret_manager_secret_iam_member.pgbackrest_tls["json-keys:ca:agora-pgbr-json-keys"]
}

moved {
  from = google_secret_manager_secret_iam_member.pgbackrest_tls["database:agora-json-keys-database"]
  to   = google_secret_manager_secret_iam_member.pgbackrest_tls["json-keys:database:agora-json-keys-database"]
}

moved {
  from = google_secret_manager_secret_iam_member.pgbackrest_tls["repository:agora-pgbr-json-keys"]
  to   = google_secret_manager_secret_iam_member.pgbackrest_tls["json-keys:repository:agora-pgbr-json-keys"]
}
