locals {
  service_agent_roles = {
    "cloudbuild.googleapis.com"  = "roles/cloudbuild.serviceAgent"
    "clouddeploy.googleapis.com" = "roles/clouddeploy.serviceAgent"
    "run.googleapis.com"         = "roles/run.serviceAgent"
  }
}

resource "google_project_service_identity" "agent" {
  provider = google-beta
  for_each = local.service_agent_roles

  project = google_project.service.project_id
  service = each.key

  depends_on = [google_project_service.api]
}

resource "google_project_iam_member" "service_agent" {
  for_each = local.service_agent_roles

  project = google_project.service.project_id
  role    = each.value
  member  = google_project_service_identity.agent[each.key].member
}
