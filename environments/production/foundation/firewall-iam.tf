# Network Admin reads firewall rules and policies and attaches a policy to the network. Writing
# either requires a separate grant.
resource "google_project_iam_custom_role" "foundation_firewall" {
  project = google_project.workload.project_id

  role_id     = "infraFoundationFirewall"
  title       = "Infra Foundation Firewall"
  description = "Maintain VPC firewall rules and network firewall policies in the workload project."
  stage       = "GA"

  permissions = [
    "compute.firewallPolicies.create",
    "compute.firewallPolicies.delete",
    "compute.firewallPolicies.update",
    "compute.firewalls.create",
    "compute.firewalls.delete",
    "compute.firewalls.update",
  ]

  depends_on = [google_project_service.workload["iam.googleapis.com"]]
}

resource "google_project_iam_member" "foundation_firewall" {
  project = google_project.workload.project_id
  role    = google_project_iam_custom_role.foundation_firewall.name
  member  = "serviceAccount:${local.automation_service_accounts.foundation}"
}
