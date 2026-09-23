# Configuration authority stays with the protected administrator. Dispatch and
# promotion belong to the service's separately reviewed operational identities.
resource "google_project_iam_custom_role" "foundation_control_plane" {
  project     = google_project.service.project_id
  role_id     = "foundationServiceControlPlane"
  title       = "Foundation service control plane"
  description = "Maintain service provisioning resources without direct rollout, job or schedule execution."
  permissions = [
    "clouddeploy.deliveryPipelines.create",
    "clouddeploy.deliveryPipelines.delete",
    "clouddeploy.deliveryPipelines.get",
    "clouddeploy.deliveryPipelines.update",
    "clouddeploy.operations.get",
    "clouddeploy.targets.create",
    "clouddeploy.targets.delete",
    "clouddeploy.targets.get",
    "clouddeploy.targets.update",
    "cloudscheduler.jobs.create",
    "cloudscheduler.jobs.delete",
    "cloudscheduler.jobs.fullView",
    "cloudscheduler.jobs.get",
    "cloudscheduler.jobs.pause",
    "cloudscheduler.jobs.update",
    "run.jobs.create",
    "run.jobs.delete",
    "run.jobs.get",
    "run.jobs.getIamPolicy",
    "run.jobs.setIamPolicy",
    "run.jobs.update",
    "run.operations.get",
    "storage.buckets.create",
    "storage.buckets.delete",
    "storage.buckets.get",
    "storage.buckets.getIamPolicy",
    "storage.buckets.setIamPolicy",
    "storage.buckets.update",
  ]

  depends_on = [google_project_service.api]
}

resource "google_project_iam_member" "foundation_control_plane" {
  project = google_project.service.project_id
  role    = google_project_iam_custom_role.foundation_control_plane.name
  member  = "serviceAccount:${var.foundation_service_account}"
}

# Viewer covers resource configuration; policy refresh requires these reads too.
resource "google_project_iam_custom_role" "plan_policy" {
  project     = google_project.service.project_id
  role_id     = "serviceFoundationPolicyViewer"
  title       = "Service foundation policy viewer"
  description = "Refresh service-foundation IAM without changing policies or reading payloads."
  permissions = [
    "artifactregistry.repositories.getIamPolicy",
    "iam.roles.get",
    "iam.serviceAccounts.getIamPolicy",
    "resourcemanager.projects.getIamPolicy",
    "run.jobs.getIamPolicy",
    "storage.buckets.getIamPolicy",
  ]

  depends_on = [google_project_service.api]
}

resource "google_project_iam_member" "plan_policy" {
  project = google_project.service.project_id
  role    = google_project_iam_custom_role.plan_policy.name
  member  = "serviceAccount:${var.plan_service_account}"
}
