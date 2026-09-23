mock_provider "google-beta" {}

mock_provider "google" {
  mock_resource "google_service_account" {
    defaults = {
      email = "runtime-mock@agora-production-test.iam.gserviceaccount.com"
      name  = "projects/agora-production-test/serviceAccounts/runtime-mock@agora-production-test.iam.gserviceaccount.com"
    }
  }
}

variables {
  management_project_id                 = "agora-management-test"
  workload_project_id                   = "agora-production-test"
  adopt_default_network                 = false
  backup_bucket_name                    = "agora-management-test-123456789012-backups"
  billing_account_id                    = "ABCDEF-123456-ABCDEF"
  cost_alert_email                      = "infra@example.com"
  operations_alert_email                = "operations@example.com"
  organization_id                       = "123456789012"
  database_operator_principals          = ["group:infra-operators@example.com"]
  authentication_initializer_principals = ["group:authentication-initializers@example.com"]
}

run "grants_only_firewall_writes_to_foundation" {
  command = plan

  assert {
    condition = (
      google_project_iam_custom_role.foundation_firewall.project == var.workload_project_id &&
      google_project_iam_custom_role.foundation_firewall.role_id == "infraFoundationFirewall" &&
      google_project_iam_custom_role.foundation_firewall.permissions == toset([
        "compute.firewalls.create",
        "compute.firewalls.delete",
        "compute.firewalls.update",
      ]) &&
      google_project_iam_member.foundation_firewall.project == var.workload_project_id &&
      google_project_iam_member.foundation_firewall.member == "serviceAccount:infra-foundation@agora-management-test.iam.gserviceaccount.com" &&
      contains(local.foundation_project_roles, "roles/compute.networkAdmin") &&
      !contains(local.foundation_project_roles, "roles/compute.securityAdmin")
    )
    error_message = "Foundation needs a workload-project firewall-write grant without broader Compute security administration."
  }
}

run "grants_recovery_firewall_writes_only_in_the_replacement" {
  command = plan

  variables {
    recovery_mode       = true
    workload_project_id = "agora-recovery-test"
  }

  assert {
    condition = (
      google_project_iam_custom_role.foundation_firewall.project == "agora-recovery-test" &&
      google_project_iam_member.foundation_firewall.project == "agora-recovery-test" &&
      google_project_iam_member.foundation_firewall.member == "serviceAccount:infra-recovery@agora-management-test.iam.gserviceaccount.com"
    )
    error_message = "Recovery firewall authority must target only the replacement project and recovery identity."
  }
}
