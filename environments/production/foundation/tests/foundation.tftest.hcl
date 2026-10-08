# Plans the committed production inputs against mocked providers.
mock_provider "google" {
  mock_resource "google_project" {
    defaults = { number = "123456789012" }
  }
  mock_resource "google_service_account" {
    defaults = {
      email  = "runtime-mock@a-novel-production-prod.iam.gserviceaccount.com"
      member = "serviceAccount:runtime-mock@a-novel-production-prod.iam.gserviceaccount.com"
      name   = "projects/a-novel-production-prod/serviceAccounts/runtime-mock@a-novel-production-prod.iam.gserviceaccount.com"
    }
  }
  mock_data "google_project" {
    defaults = { number = "232403541574" }
  }
  mock_data "google_compute_instance_group" {
    defaults = { instances = ["projects/a-novel-production-prod/zones/europe-west1-d/instances/agora-database-mock"] }
  }
}

mock_provider "google-beta" {
  mock_resource "google_project_service_identity" {
    defaults = { member = "serviceAccount:mock-agent@gcp-sa-cloudscheduler.iam.gserviceaccount.com" }
  }
}

run "keeps_databases_private_and_preserved" {
  command = plan

  assert {
    condition = alltrue([for template in google_compute_instance_template.database :
      length(template.network_interface[0].access_config) == 0 &&
      template.shielded_instance_config[0].enable_secure_boot &&
      anytrue([for disk in template.disk : !disk.boot && !disk.auto_delete])
    ])
    error_message = "Database hosts must have no external IP, boot securely and never delete their data disk."
  }

  assert {
    condition = alltrue([for group in google_compute_instance_group_manager.database :
      one(group.stateful_disk).delete_rule == "NEVER" &&
      one(group.stateful_internal_ip).delete_rule == "NEVER" &&
      group.update_policy[0].type == "OPPORTUNISTIC"
    ])
    error_message = "Database groups must keep their disk and address, and roll hosts only through manual maintenance."
  }

  assert {
    condition     = alltrue([for disk in google_compute_disk.database : disk.deletion_policy == "PREVENT"])
    error_message = "Database data disks must refuse deletion."
  }
}

run "denies_everything_the_network_does_not_allow" {
  command = plan

  assert {
    condition = (
      google_compute_firewall.deny_other_egress.direction == "EGRESS" &&
      google_compute_firewall.deny_other_egress.destination_ranges == toset(["0.0.0.0/0"]) &&
      google_compute_firewall.deny_other_egress.target_tags == null &&
      alltrue([for rule in concat(values(google_compute_firewall.allow_postgres_egress), [google_compute_firewall.allow_restricted_google_apis]) :
        rule.priority < google_compute_firewall.deny_other_egress.priority
      ])
    )
    error_message = "A VPC-wide deny must sit below every explicit egress allow."
  }

  assert {
    condition = (
      google_compute_firewall.allow_iap_ssh.source_ranges == toset(["35.235.240.0/20"]) &&
      alltrue([for rule in google_compute_firewall.allow_postgres_ingress : rule.source_ranges == toset([var.subnet_cidr])])
    )
    error_message = "SSH must come only from Identity-Aware Proxy, and PostgreSQL only from the private subnet."
  }
}

run "grants_no_basic_roles" {
  command = plan

  assert {
    condition = alltrue([for binding in concat(values(google_project_iam_member.foundation), values(google_project_iam_member.database_operator)) :
      !contains(["roles/owner", "roles/editor"], binding.role)
    ])
    error_message = "Automation and operators get scoped roles, never owner or editor."
  }

  assert {
    condition     = !google_cloud_scheduler_job.json_keys_rotation[0].paused
    error_message = "Key rotation must stay scheduled."
  }
}
