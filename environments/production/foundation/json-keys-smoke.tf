# The probe keeps the JSON Keys identity and its existing secret allowlist.
resource "google_project_iam_member" "json_keys_smoke_invoker" {
  count = var.recovery_mode ? 0 : 1

  project = google_project.workload.project_id
  role    = "roles/run.servicesInvoker"
  member  = "serviceAccount:${google_service_account.runtime["json_keys"].email}"

  condition {
    title       = "JSONKeysInternalSmokeOnly"
    description = "JSON Keys may probe services tagged for private internal invocation."
    expression  = "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["internal"].id}')"
  }
}
