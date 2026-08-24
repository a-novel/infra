mock_provider "google" {
  mock_resource "google_project" {
    defaults = {
      number = "987654321098"
    }
  }

  mock_resource "google_service_account" {
    defaults = {
      email = "runtime-mock@agora-production-test.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_artifact_registry_repository" {
    defaults = {
      registry_uri = "europe-west1-docker.pkg.dev/agora-production-test/agora-production"
    }
  }

  mock_resource "google_monitoring_notification_channel" {
    defaults = {
      name = "projects/agora-production-test/notificationChannels/cost-email"
    }
  }

  mock_data "google_billing_account" {
    defaults = {
      currency_code = "EUR"
    }
  }

  mock_data "google_cloud_quotas_quota_infos" {
    defaults = {
      quota_infos = [
        {
          container_type             = "PROJECT"
          dimensions                 = ["region"]
          dimensions_infos           = []
          is_concurrent              = true
          is_fixed                   = false
          is_precise                 = true
          metric                     = "run.googleapis.com/cpu_allocation"
          metric_display_name        = "CPU allocation"
          metric_unit                = "milli-vCPU"
          name                       = "services/run.googleapis.com/quotaInfos/CpuAllocPerProjectRegion"
          quota_display_name         = "CPU allocation"
          quota_id                   = "CpuAllocPerProjectRegion"
          quota_increase_eligibility = []
          refresh_interval           = "60s"
          service                    = "run.googleapis.com"
          service_request_quota_uri  = ""
        },
        {
          container_type             = "PROJECT"
          dimensions                 = ["region"]
          dimensions_infos           = []
          is_concurrent              = true
          is_fixed                   = false
          is_precise                 = true
          metric                     = "run.googleapis.com/mem_allocation"
          metric_display_name        = "Memory allocation"
          metric_unit                = "By"
          name                       = "services/run.googleapis.com/quotaInfos/MemAllocPerProjectRegion"
          quota_display_name         = "Memory allocation"
          quota_id                   = "MemAllocPerProjectRegion"
          quota_increase_eligibility = []
          refresh_interval           = "60s"
          service                    = "run.googleapis.com"
          service_request_quota_uri  = ""
        },
        {
          container_type             = "PROJECT"
          dimensions                 = ["region"]
          dimensions_infos           = []
          is_concurrent              = true
          is_fixed                   = false
          is_precise                 = true
          metric                     = "run.googleapis.com/instance_limit_regional"
          metric_display_name        = "Direct VPC instances"
          metric_unit                = "1"
          name                       = "services/run.googleapis.com/quotaInfos/MaxInstancesLimitWithDirectVpcEgressPerProjectRegion"
          quota_display_name         = "Direct VPC instances"
          quota_id                   = "MaxInstancesLimitWithDirectVpcEgressPerProjectRegion"
          quota_increase_eligibility = []
          refresh_interval           = "60s"
          service                    = "run.googleapis.com"
          service_request_quota_uri  = ""
        },
        {
          container_type             = "PROJECT"
          dimensions                 = ["region"]
          dimensions_infos           = []
          is_concurrent              = true
          is_fixed                   = false
          is_precise                 = true
          metric                     = "compute.googleapis.com/cpus"
          metric_display_name        = "CPUs"
          metric_unit                = "1"
          name                       = "services/compute.googleapis.com/quotaInfos/CPUS-per-project-region"
          quota_display_name         = "CPUs"
          quota_id                   = "CPUS-per-project-region"
          quota_increase_eligibility = []
          refresh_interval           = "60s"
          service                    = "compute.googleapis.com"
          service_request_quota_uri  = ""
        },
      ]
    }
  }
}

variables {
  management_project_id = "agora-management-test"
  workload_project_id   = "agora-production-test"
  billing_account_id    = "ABCDEF-123456-ABCDEF"
  cost_alert_email      = "infra@example.com"
}

run "builds_the_protected_workload_foundation" {
  command = plan

  assert {
    condition = (
      output.root_name == "foundation" &&
      output.region == "europe-west1" &&
      output.workload_project_id == "agora-production-test" &&
      output.workload_project_number == "987654321098"
    )
    error_message = "The foundation identity, region, or project outputs changed."
  }

  assert {
    condition = (
      google_project.workload.auto_create_network == false &&
      google_project.workload.deletion_policy == "PREVENT" &&
      google_project.workload.labels == tomap(local.labels) &&
      google_project.workload.billing_account == "ABCDEF-123456-ABCDEF"
    )
    error_message = "The workload project lost billing, labels, automatic-network prevention, or deletion protection."
  }

  assert {
    condition = (
      length(google_project_service.workload) == 10 &&
      toset(keys(google_project_service.workload)) == toset([
        "artifactregistry.googleapis.com",
        "cloudquotas.googleapis.com",
        "cloudresourcemanager.googleapis.com",
        "compute.googleapis.com",
        "dns.googleapis.com",
        "iam.googleapis.com",
        "logging.googleapis.com",
        "monitoring.googleapis.com",
        "run.googleapis.com",
        "serviceusage.googleapis.com",
      ]) &&
      alltrue([
        for service in values(google_project_service.workload) :
        !service.disable_on_destroy && !service.disable_dependent_services
      ])
    )
    error_message = "The minimal workload API set or non-disabling lifecycle changed."
  }

  assert {
    condition = (
      !google_compute_network.production.auto_create_subnetworks &&
      google_compute_network.production.delete_default_routes_on_create &&
      google_compute_network.production.mtu == 1460 &&
      google_compute_network.production.routing_mode == "REGIONAL" &&
      google_compute_subnetwork.production.ip_cidr_range == "10.20.0.0/24" &&
      google_compute_subnetwork.production.private_ip_google_access &&
      google_compute_subnetwork.production.stack_type == "IPV4_ONLY"
    )
    error_message = "The custom VPC or private production subnet contract changed."
  }

  assert {
    condition = (
      length(google_compute_route.restricted_google_apis) == 2 &&
      toset([for route in values(google_compute_route.restricted_google_apis) : route.dest_range]) ==
      toset(["199.36.153.4/30", "34.126.0.0/18"]) &&
      alltrue([
        for route in values(google_compute_route.restricted_google_apis) :
        route.next_hop_gateway == "default-internet-gateway"
      ])
    )
    error_message = "The no-default-route network must retain only the two explicit restricted Google routes."
  }

  assert {
    condition = (
      google_compute_firewall.allow_restricted_google_apis.direction == "EGRESS" &&
      google_compute_firewall.allow_restricted_google_apis.priority < google_compute_firewall.deny_other_egress.priority &&
      toset(google_compute_firewall.allow_restricted_google_apis.destination_ranges) ==
      toset(["199.36.153.4/30", "34.126.0.0/18"]) &&
      toset(google_compute_firewall.allow_restricted_google_apis.target_tags) == toset([
        "agora-authentication",
        "agora-backup",
        "agora-database",
        "agora-json-keys",
        "agora-restore",
      ]) &&
      one(google_compute_firewall.allow_restricted_google_apis.allow).protocol == "tcp" &&
      toset(one(google_compute_firewall.allow_restricted_google_apis.allow).ports) == toset(["443"]) &&
      google_compute_firewall.deny_other_egress.direction == "EGRESS" &&
      google_compute_firewall.deny_other_egress.priority == 1200 &&
      toset(google_compute_firewall.deny_other_egress.destination_ranges) == toset(["0.0.0.0/0"]) &&
      google_compute_firewall.deny_other_egress.target_tags == null &&
      one(google_compute_firewall.deny_other_egress.deny).protocol == "all"
    )
    error_message = "Reviewed tagged allows must precede the VPC-wide deny-all egress rule."
  }

  assert {
    condition = (
      google_compute_firewall.allow_postgres_egress.direction == "EGRESS" &&
      google_compute_firewall.allow_postgres_egress.priority == 810 &&
      toset(google_compute_firewall.allow_postgres_egress.target_tags) == local.database_caller_tags &&
      one(google_compute_firewall.allow_postgres_egress.allow).protocol == "tcp" &&
      toset(one(google_compute_firewall.allow_postgres_egress.allow).ports) == toset(["5432"]) &&
      google_compute_firewall.allow_postgres_ingress.direction == "INGRESS" &&
      toset(google_compute_firewall.allow_postgres_ingress.source_ranges) == toset(["10.20.0.0/24"]) &&
      toset(google_compute_firewall.allow_postgres_ingress.target_tags) == toset(["agora-database"]) &&
      one(google_compute_firewall.allow_postgres_ingress.allow).protocol == "tcp" &&
      toset(one(google_compute_firewall.allow_postgres_ingress.allow).ports) == toset(["5432"]) &&
      google_compute_firewall.allow_iap_ssh.direction == "INGRESS" &&
      toset(google_compute_firewall.allow_iap_ssh.source_ranges) == toset(["35.235.240.0/20"]) &&
      toset(google_compute_firewall.allow_iap_ssh.target_tags) == toset(["agora-database"]) &&
      toset(one(google_compute_firewall.allow_iap_ssh.allow).ports) == toset(["22"])
    )
    error_message = "PostgreSQL must accept only private-subnet traffic and SSH through IAP."
  }

  assert {
    condition = (
      google_dns_managed_zone.googleapis.visibility == "private" &&
      google_dns_managed_zone.googleapis.dns_name == "googleapis.com." &&
      length(google_dns_managed_zone.private_google_domain) == 2 &&
      toset([for zone in values(google_dns_managed_zone.private_google_domain) : zone.dns_name]) ==
      toset(["pkg.dev.", "run.app."]) &&
      google_dns_record_set.restricted_googleapis.rrdatas == tolist(local.restricted_google_vip_addresses) &&
      alltrue([
        for record in values(google_dns_record_set.private_google_domain_apex) :
        record.rrdatas == tolist(local.restricted_google_vip_addresses)
      ])
    )
    error_message = "Private DNS must retain googleapis.com, pkg.dev, run.app, and the documented restricted VIPs."
  }

  assert {
    condition = (
      google_project_default_service_accounts.workload.project == "agora-production-test" &&
      google_project_default_service_accounts.workload.action == "DEPRIVILEGE" &&
      length(google_service_account.runtime) == 6 &&
      {
        for name, identity in local.runtime_identities : name => identity.account_id
        } == {
        authentication    = "agora-authentication"
        backup            = "agora-backup"
        database          = "agora-database-host"
        json_keys         = "agora-json-keys"
        restore           = "agora-restore"
        scheduler_invoker = "agora-scheduler-invoker"
      } &&
      alltrue([
        for account in values(google_service_account.runtime) :
        account.deletion_policy == "PREVENT"
      ]) &&
      length(google_secret_manager_secret_iam_member.runtime) == 7 &&
      local.runtime_secret_access == {
        "authentication:postgres-dsn" = {
          identity = "authentication"
          secret   = "production-authentication-postgres-dsn"
        }
        "authentication:smtp-password" = {
          identity = "authentication"
          secret   = "production-authentication-smtp-sender-password"
        }
        "authentication:super-admin-password" = {
          identity = "authentication"
          secret   = "production-authentication-super-admin-password"
        }
        "database:authentication-password" = {
          identity = "database"
          secret   = "production-authentication-postgres-password"
        }
        "database:json-keys-password" = {
          identity = "database"
          secret   = "production-json-keys-postgres-password"
        }
        "json-keys:app-master-key" = {
          identity = "json_keys"
          secret   = "production-json-keys-app-master-key"
        }
        "json-keys:postgres-dsn" = {
          identity = "json_keys"
          secret   = "production-json-keys-postgres-dsn"
        }
      } &&
      alltrue([
        for binding in values(google_secret_manager_secret_iam_member.runtime) :
        binding.role == "roles/secretmanager.secretAccessor"
      ])
    )
    error_message = "Default-account deprivileging, runtime identities, or exact per-secret access changed."
  }

  assert {
    condition = (
      local.foundation_project_roles == toset([
        "roles/artifactregistry.admin",
        "roles/billing.projectManager",
        "roles/cloudquotas.admin",
        "roles/compute.networkAdmin",
        "roles/dns.admin",
        "roles/iam.roleAdmin",
        "roles/iam.serviceAccountAdmin",
        "roles/logging.configWriter",
        "roles/monitoring.notificationChannelEditor",
        "roles/resourcemanager.projectIamAdmin",
        "roles/serviceusage.serviceUsageAdmin",
      ]) &&
      alltrue([
        for binding in values(google_project_iam_member.foundation) :
        !contains(["roles/owner", "roles/editor"], binding.role)
      ]) &&
      !contains(local.foundation_project_roles, "roles/compute.instanceAdmin.v1") &&
      google_project_iam_custom_role.foundation_project_metadata.permissions == toset([
        "resourcemanager.projects.get",
        "resourcemanager.projects.list",
        "resourcemanager.projects.update",
      ])
    )
    error_message = "Foundation IAM must remain least-privilege and omit primitive, VM, move, and delete authority."
  }

  assert {
    condition = (
      google_artifact_registry_repository.production.format == "DOCKER" &&
      google_artifact_registry_repository.production.location == "europe-west1" &&
      google_artifact_registry_repository.production.docker_config[0].immutable_tags &&
      google_artifact_registry_repository.production.cleanup_policy_dry_run &&
      {
        for policy in google_artifact_registry_repository.production.cleanup_policies :
        policy.id => policy.action
        } == {
        "delete-old-versions"     = "DELETE"
        "retain-recent-versions"  = "KEEP"
        "retain-release-receipts" = "KEEP"
      } &&
      google_artifact_registry_repository_iam_member.release_writer.role == "roles/artifactregistry.writer" &&
      google_artifact_registry_repository_iam_member.release_writer.member == "serviceAccount:infra-release@agora-management-test.iam.gserviceaccount.com" &&
      google_artifact_registry_repository_iam_member.database_reader.role == "roles/artifactregistry.reader" &&
      google_artifact_registry_repository_iam_member.database_reader.member == "serviceAccount:${google_service_account.runtime["database"].email}"
    )
    error_message = "The immutable regional registry, dry-run cleanup policy, or write/read split changed."
  }

  assert {
    condition = (
      length(google_cloud_quotas_quota_preference.cost_cap) == 4 &&
      alltrue([
        for preference in values(google_cloud_quotas_quota_preference.cost_cap) :
        preference.dimensions == tomap({ region = "europe-west1" }) &&
        preference.contact_email == "infra-foundation@agora-management-test.iam.gserviceaccount.com" &&
        preference.ignore_safety_checks == "QUOTA_DECREASE_PERCENTAGE_TOO_HIGH"
      ]) &&
      google_cloud_quotas_quota_preference.cost_cap["cloud_run_cpu"].service == "run.googleapis.com" &&
      local.quota_preferences["cloud_run_cpu"].metric == "run.googleapis.com/cpu_allocation" &&
      local.quota_preferences["cloud_run_memory"].metric == "run.googleapis.com/mem_allocation" &&
      local.quota_preferences["cloud_run_direct_vpc_instances"].metric == "run.googleapis.com/instance_limit_regional" &&
      google_cloud_quotas_quota_preference.cost_cap["compute_cpu"].service == "compute.googleapis.com" &&
      local.quota_preferences["compute_cpu"].metric == "compute.googleapis.com/cpus" &&
      google_cloud_quotas_quota_preference.cost_cap["cloud_run_cpu"].quota_config[0].preferred_value == "8000" &&
      google_cloud_quotas_quota_preference.cost_cap["cloud_run_memory"].quota_config[0].preferred_value == "17179869184" &&
      google_cloud_quotas_quota_preference.cost_cap["cloud_run_direct_vpc_instances"].quota_config[0].preferred_value == "20" &&
      google_cloud_quotas_quota_preference.cost_cap["compute_cpu"].quota_config[0].preferred_value == "4"
    )
    error_message = "The explicit regional Cloud Run or Compute Engine cost ceilings changed."
  }

  assert {
    condition = (
      google_monitoring_notification_channel.cost_email.type == "email" &&
      google_monitoring_notification_channel.cost_email.enabled &&
      google_monitoring_notification_channel.cost_email.labels == tomap({ email_address = "infra@example.com" }) &&
      google_monitoring_notification_channel.cost_email.deletion_policy == "PREVENT" &&
      google_billing_budget.workload.amount[0].specified_amount[0].units == "60" &&
      google_billing_budget.workload.amount[0].specified_amount[0].currency_code == "EUR" &&
      toset(google_billing_budget.workload.budget_filter[0].projects) == toset(["projects/987654321098"]) &&
      toset([
        for threshold in google_billing_budget.workload.threshold_rules :
        "${threshold.spend_basis}:${threshold.threshold_percent}"
        ]) == toset([
        "CURRENT_SPEND:0.5",
        "CURRENT_SPEND:0.75",
        "CURRENT_SPEND:0.9",
        "CURRENT_SPEND:1",
        "FORECASTED_SPEND:1",
      ]) &&
      google_billing_budget.workload.all_updates_rule[0].disable_default_iam_recipients &&
      !google_billing_budget.workload.all_updates_rule[0].enable_project_level_recipients &&
      toset(google_billing_budget.workload.all_updates_rule[0].monitoring_notification_channels) == toset([google_monitoring_notification_channel.cost_email.name]) &&
      google_logging_project_bucket_config.default.retention_days == 30 &&
      strcontains(google_logging_project_exclusion.successful_healthchecks.filter, "httpRequest.status>=200") &&
      strcontains(google_logging_project_exclusion.successful_healthchecks.filter, "/v2/healthcheck") &&
      !strcontains(google_logging_project_exclusion.successful_healthchecks.filter, "severity")
    )
    error_message = "Budget notification or bounded logging controls changed."
  }
}

run "rejects_an_invalid_workload_project_id" {
  command = plan

  variables {
    workload_project_id = "INVALID"
  }

  expect_failures = [var.workload_project_id]
}

run "rejects_an_invalid_management_project_id" {
  command = plan

  variables {
    management_project_id = "INVALID"
  }

  expect_failures = [var.management_project_id]
}

run "rejects_an_invalid_billing_account" {
  command = plan

  variables {
    billing_account_id = "not-a-billing-account"
  }

  expect_failures = [var.billing_account_id]
}

run "rejects_an_invalid_cost_email" {
  command = plan

  variables {
    cost_alert_email = "not-an-email"
  }

  expect_failures = [var.cost_alert_email]
}

run "rejects_a_non_ipv4_24_subnet" {
  command = plan

  variables {
    subnet_cidr = "10.20.0.0/16"
  }

  expect_failures = [var.subnet_cidr]
}

run "rejects_two_project_parents" {
  command = plan

  variables {
    organization_id = "123456789012"
    folder_id       = "234567890123"
  }

  expect_failures = [google_project.workload]
}

run "rejects_an_unreviewed_compute_scale" {
  command = plan

  variables {
    compute_cpu_quota = 64
  }

  expect_failures = [var.compute_cpu_quota]
}
