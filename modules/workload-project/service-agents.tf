locals {
  service_agent_roles = {
    "cloudbuild.googleapis.com"     = "roles/cloudbuild.serviceAgent"
    "clouddeploy.googleapis.com"    = "roles/clouddeploy.serviceAgent"
    "cloudscheduler.googleapis.com" = "roles/cloudscheduler.serviceAgent"
    "compute.googleapis.com"        = "roles/compute.serviceAgent"
    "run.googleapis.com"            = "roles/run.serviceAgent"
    "workflows.googleapis.com"      = "roles/workflows.serviceAgent"
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

# Google APIs, not the VM runtime or Compute Engine agent, manages MIG members.
resource "google_project_iam_member" "mig_agent" {
  project = google_project.service.project_id
  role    = "roles/compute.instanceGroupManagerServiceAgent"
  member  = "serviceAccount:${google_project.service.number}@cloudservices.gserviceaccount.com"

  depends_on = [google_project_service.api["compute.googleapis.com"]]
}
