# Network Admin supplies firewall reads, but firewall writes require a separate grant.
resource "google_project_iam_custom_role" "foundation_firewall" {
  project = google_project.workload.project_id

  role_id     = "infraFoundationFirewall"
  title       = "Infra Foundation Firewall"
  description = "Maintain VPC firewall rules in the workload project."
  stage       = "GA"

  permissions = [
    "compute.firewalls.create",
    "compute.firewalls.delete",
    "compute.firewalls.update",
  ]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "foundation_firewall" {
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_firewall.name
  member  = "serviceAccount:${local.automation_service_accounts[var.recovery_mode ? "recovery" : "foundation"]}"
}
