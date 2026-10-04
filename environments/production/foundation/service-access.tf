resource "google_project_iam_custom_role" "foundation_service_access" {
  count = contains(keys(local.service_release_boundaries), "authentication/public-api") ? 1 : 0

  project     = google_project.workload.project_id
  role_id     = "infraFoundationServiceAccess"
  title       = "Foundation Cloud Run service access"
  description = "Manage invocation policies on the tagged internal services."
  permissions = ["run.services.getIamPolicy", "run.services.setIamPolicy"]
}

resource "google_project_iam_member" "foundation_service_access" {
  count = length(google_project_iam_custom_role.foundation_service_access)

  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_service_access[0].name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"

  condition {
    title       = "InternalCloudRunOnly"
    description = "Foundation may manage invocation only on tagged private internal services."
    expression  = "resource.matchTagId('${google_tags_tag_key.cloud_run_invocation.id}', '${google_tags_tag_value.cloud_run_invocation["internal"].id}')"
  }
}
