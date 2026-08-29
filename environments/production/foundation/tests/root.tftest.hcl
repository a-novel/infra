mock_provider "google" {
  mock_resource "google_project" {
    defaults = {
      number = "987654321098"
    }
  }

  mock_resource "google_service_account" {
    defaults = {
      email = "runtime-mock@agora-production-test.iam.gserviceaccount.com"
      name  = "projects/agora-production-test/serviceAccounts/runtime-mock@agora-production-test.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_artifact_registry_repository" {
    defaults = {
      registry_uri = "europe-west1-docker.pkg.dev/agora-production-test/agora-production"
    }
  }

  mock_resource "google_tags_tag_key" {
    defaults = {
      id   = "tagKeys/100000000001"
      name = "100000000001"
    }
  }

  mock_resource "google_tags_tag_value" {
    defaults = {
      id   = "tagValues/200000000001"
      name = "200000000001"
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

  mock_data "google_project" {
    defaults = {
      number = "123456789012"
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
        # Google exposes zonal and regional Compute CPU records under the same
        # metric. Only the regional record is valid for this preference.
        {
          container_type             = "PROJECT"
          dimensions                 = ["zone"]
          dimensions_infos           = []
          is_concurrent              = true
          is_fixed                   = false
          is_precise                 = true
          metric                     = "compute.googleapis.com/cpus"
          metric_display_name        = "CPUs"
          metric_unit                = "1"
          name                       = "services/compute.googleapis.com/quotaInfos/CPUS-per-project-zone"
          quota_display_name         = "CPUs"
          quota_id                   = "CPUS-per-project-zone"
          quota_increase_eligibility = []
          refresh_interval           = "60s"
          service                    = "compute.googleapis.com"
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

  mock_data "google_compute_instance_group" {
    defaults = {
      instances = ["projects/agora-production-test/zones/europe-west1-c/instances/agora-database-abcd"]
      size      = 1
    }
  }

  mock_data "google_compute_instance" {
    defaults = {
      name = "agora-database-abcd"
      network_interface = [
        {
          network_ip = "10.20.0.5"
        },
      ]
    }
  }
}

variables {
  management_project_id = "agora-management-test"
  workload_project_id   = "agora-production-test"
  # OpenTofu's test context cannot execute configuration-driven imports.
  adopt_default_network  = false
  backup_bucket_name     = "agora-management-test-123456789012-backups"
  billing_account_id     = "ABCDEF-123456-ABCDEF"
  cost_alert_email       = "infra@example.com"
  operations_alert_email = "operations@example.com"
  organization_id        = "123456789012"
  database_operator_principals = [
    "group:infra-operators@example.com",
  ]
  authentication_initializer_principals = [
    "group:authentication-initializers@example.com",
  ]
}

run "builds_the_protected_workload_foundation" {
  command = plan

  assert {
    condition = (
      output.root_name == "foundation" &&
      output.region == "europe-west1" &&
      output.workload_project_id == "agora-production-test" &&
      output.workload_project_number == "987654321098" &&
      output.cloud_run_invocation_tags.key == "tagKeys/100000000001" &&
      toset(keys(output.cloud_run_invocation_tags.values)) == toset([
        "initializer",
        "internal",
        "recovery",
        "release",
        "scheduled",
      ])
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
      length(google_project_service.workload) == 13 &&
      toset(keys(google_project_service.workload)) == toset([
        "artifactregistry.googleapis.com",
        "cloudscheduler.googleapis.com",
        "cloudquotas.googleapis.com",
        "cloudresourcemanager.googleapis.com",
        "compute.googleapis.com",
        "dns.googleapis.com",
        "iam.googleapis.com",
        "iap.googleapis.com",
        "logging.googleapis.com",
        "monitoring.googleapis.com",
        "oslogin.googleapis.com",
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
      length(google_compute_firewall.allow_postgres_egress) == 2 &&
      alltrue([
        for key, rule in google_compute_firewall.allow_postgres_egress :
        rule.direction == "EGRESS" &&
        rule.priority == 810 &&
        toset(rule.target_tags) == local.database_egress_contracts[key].target_tags &&
        !contains(rule.target_tags, "agora-restore") &&
        one(rule.allow).protocol == "tcp" &&
        toset(one(rule.allow).ports) == toset([tostring(local.database_egress_contracts[key].port)])
      ]) &&
      google_compute_firewall.allow_postgres_ingress.direction == "INGRESS" &&
      toset(google_compute_firewall.allow_postgres_ingress.source_ranges) == toset(["10.20.0.0/24"]) &&
      toset(google_compute_firewall.allow_postgres_ingress.target_tags) == toset(["agora-database"]) &&
      one(google_compute_firewall.allow_postgres_ingress.allow).protocol == "tcp" &&
      toset(one(google_compute_firewall.allow_postgres_ingress.allow).ports) == toset(["5432", "5433"]) &&
      google_compute_firewall.allow_iap_ssh.direction == "INGRESS" &&
      toset(google_compute_firewall.allow_iap_ssh.source_ranges) == toset(["35.235.240.0/20"]) &&
      toset(google_compute_firewall.allow_iap_ssh.target_tags) == toset(["agora-database"]) &&
      toset(one(google_compute_firewall.allow_iap_ssh.allow).ports) == toset(["22"])
    )
    error_message = "PostgreSQL must accept only per-database caller egress, private-subnet ingress, and SSH through IAP."
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
      length(google_service_account.runtime) == 7 &&
      {
        for name, identity in local.runtime_identities : name => identity.account_id
        } == {
        authentication             = "agora-authentication"
        authentication_initializer = "agora-auth-initializer"
        backup                     = "agora-backup"
        database                   = "agora-database-host"
        json_keys                  = "agora-json-keys"
        restore                    = "agora-restore"
        scheduler_invoker          = "agora-scheduler-invoker"
      } &&
      alltrue([
        for account in values(google_service_account.runtime) :
        account.deletion_policy == "PREVENT"
      ]) &&
      length(google_secret_manager_secret_iam_member.runtime) == 12 &&
      local.runtime_secret_access == {
        "authentication:postgres-dsn" = {
          identity = "authentication"
          secret   = "production-authentication-postgres-dsn"
        }
        "authentication:smtp-password" = {
          identity = "authentication"
          secret   = "production-authentication-smtp-sender-password"
        }
        "authentication-initializer:postgres-dsn" = {
          identity = "authentication_initializer"
          secret   = "production-authentication-postgres-dsn"
        }
        "authentication-initializer:super-admin-password" = {
          identity = "authentication_initializer"
          secret   = "production-authentication-super-admin-password"
        }
        "database:authentication-password" = {
          identity = "database"
          secret   = "production-authentication-postgres-password"
        }
        "database:authentication-backup-password" = {
          identity = "database"
          secret   = "production-authentication-postgres-backup-password"
        }
        "database:json-keys-password" = {
          identity = "database"
          secret   = "production-json-keys-postgres-password"
        }
        "database:json-keys-backup-password" = {
          identity = "database"
          secret   = "production-json-keys-postgres-backup-password"
        }
        "backup:authentication-backup-password" = {
          identity = "backup"
          secret   = "production-authentication-postgres-backup-password"
        }
        "backup:json-keys-backup-password" = {
          identity = "backup"
          secret   = "production-json-keys-postgres-backup-password"
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
        "roles/compute.instanceAdmin.v1",
        "roles/compute.networkAdmin",
        "roles/dns.admin",
        "roles/iam.roleAdmin",
        "roles/iam.serviceAccountAdmin",
        "roles/logging.configWriter",
        "roles/monitoring.alertPolicyEditor",
        "roles/monitoring.notificationChannelEditor",
        "roles/resourcemanager.projectIamAdmin",
        "roles/resourcemanager.tagAdmin",
        "roles/serviceusage.serviceUsageAdmin",
      ]) &&
      alltrue([
        for binding in values(google_project_iam_member.foundation) :
        !contains(["roles/owner", "roles/editor"], binding.role)
      ]) &&
      google_project_iam_custom_role.foundation_project_metadata.permissions == toset([
        "resourcemanager.projects.get",
        "resourcemanager.projects.update",
      ]) &&
      length(google_project_iam_member.recovery_project_deleter) == 0 &&
      length(google_project_iam_member.plan_viewer) == 1 &&
      google_project_iam_member.plan_viewer[0].role == "roles/viewer" &&
      google_project_iam_member.plan_viewer[0].member == "serviceAccount:infra-plan@agora-management-test.iam.gserviceaccount.com"
    )
    error_message = "Foundation IAM must remain least-privilege and omit primitive, project-move, and project-delete authority."
  }

  assert {
    condition = (
      google_compute_disk.database.type == "pd-balanced" &&
      google_compute_disk.database.size == 50 &&
      google_compute_disk.database.physical_block_size_bytes == 4096 &&
      google_compute_disk.database.deletion_policy == "PREVENT" &&
      google_compute_instance_template.database.machine_type == "e2-medium" &&
      length(one(google_compute_instance_template.database.network_interface).access_config) == 0 &&
      one(google_compute_instance_template.database.service_account).email == google_service_account.runtime["database"].email &&
      toset(one(google_compute_instance_template.database.service_account).scopes) == toset(["cloud-platform"]) &&
      one(google_compute_instance_template.database.shielded_instance_config).enable_secure_boot &&
      one(google_compute_instance_template.database.shielded_instance_config).enable_vtpm &&
      one(google_compute_instance_template.database.shielded_instance_config).enable_integrity_monitoring &&
      google_compute_instance_template.database.metadata["enable-oslogin"] == "TRUE" &&
      google_compute_instance_template.database.metadata["block-project-ssh-keys"] == "TRUE" &&
      google_compute_instance_template.database.metadata["cos-update-strategy"] == "update_disabled" &&
      google_compute_instance_template.database.metadata["serial-port-enable"] == "FALSE" &&
      google_compute_instance_template.database.metadata["agora-database-data-disk-size-gb"] == "50" &&
      !contains(keys(google_compute_instance_template.database.metadata), "agora-database-release-revision") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "POSTGRES_PASSWORD_FILE=") &&
      !strcontains(google_compute_instance_template.database.metadata_startup_script, "POSTGRES_PASSWORD=") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "--auth-local=trust") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "pg_read_file('/run/agora-postgres-password')") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "pg_read_file('/run/agora-postgres-backup-password')") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "GRANT pg_read_all_data") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "database backup role has an undeclared membership") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "NOBYPASSRLS CONNECTION LIMIT 2") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "agora.database_image=$${image}") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "log_min_error_statement=panic") &&
      !strcontains(google_compute_instance_template.database.metadata_startup_script, "\\gexec") &&
      !strcontains(google_compute_instance_template.database.metadata_startup_script, "--tty") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "^[A-Za-z0-9_-]+$") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "cmp -s") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "findmnt -n -o SOURCE") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "\"credHelpers\"") &&
      !strcontains(google_compute_instance_template.database.metadata_startup_script, "HOME=") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "AGORA-DATABASE-EGRESS") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "--subnet") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "--dns 127.0.0.1") &&
      !strcontains(google_compute_instance_template.database.metadata_startup_script, "--internal") &&
      strcontains(google_compute_instance_template.database.metadata_startup_script, "--restart on-failure:5") &&
      !strcontains(google_compute_instance_template.database.metadata_startup_script, "--restart unless-stopped") &&
      length(google_compute_instance_template.database.disk) == 2 &&
      one([
        for disk in google_compute_instance_template.database.disk : disk
        if disk.device_name == "agora-data"
      ]).auto_delete == false &&
      one([
        for disk in google_compute_instance_template.database.disk : disk
        if disk.device_name == "agora-data"
      ]).source == google_compute_disk.database.name &&
      google_compute_instance_group_manager.database.target_size == 1 &&
      google_compute_instance_group_manager.database.deletion_policy == "PREVENT" &&
      one(google_compute_instance_group_manager.database.stateful_disk).device_name == "agora-data" &&
      one(google_compute_instance_group_manager.database.stateful_disk).delete_rule == "NEVER" &&
      one(google_compute_instance_group_manager.database.stateful_internal_ip).interface_name == "nic0" &&
      one(google_compute_instance_group_manager.database.stateful_internal_ip).delete_rule == "NEVER" &&
      one(google_compute_instance_group_manager.database.all_instances_config).metadata == tomap({
        agora-authentication-database-image                   = ""
        agora-authentication-postgres-backup-password-version = "0"
        agora-authentication-postgres-password-version        = "0"
        agora-database-release-revision                       = ""
        agora-json-keys-database-image                        = ""
        agora-json-keys-postgres-backup-password-version      = "0"
        agora-json-keys-postgres-password-version             = "0"
      }) &&
      one(google_compute_instance_group_manager.database.update_policy).type == "OPPORTUNISTIC" &&
      one(google_compute_instance_group_manager.database.update_policy).replacement_method == "RECREATE" &&
      one(google_compute_instance_group_manager.database.update_policy).max_surge_fixed == 0 &&
      one(google_compute_instance_group_manager.database.update_policy).max_unavailable_fixed == 1 &&
      google_compute_instance_group_manager.database.wait_for_instances_status == "STABLE" &&
      output.database_host.ports == local.database_ports
    )
    error_message = "The private stateful database host, preserved disk, or capacity defaults changed."
  }

  assert {
    condition = (
      google_project_iam_member.mig_service_agent.role == "roles/compute.instanceGroupManagerServiceAgent" &&
      google_project_iam_member.mig_service_agent.member == "serviceAccount:987654321098@cloudservices.gserviceaccount.com" &&
      google_service_account_iam_member.foundation_database_act_as.role == "roles/iam.serviceAccountUser" &&
      google_service_account_iam_member.mig_database_act_as.member == "serviceAccount:987654321098@cloudservices.gserviceaccount.com" &&
      local.database_runtime_project_roles == toset([
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
      ]) &&
      length(google_project_iam_member.database_runtime_observability) == 2 &&
      local.database_operator_project_roles == toset([
        "roles/compute.osAdminLogin",
        "roles/compute.viewer",
        "roles/logging.viewer",
      ]) &&
      length(google_project_iam_member.database_operator) == 3 &&
      one(values(google_project_iam_member.database_operator_iap)).role == "roles/iap.tunnelResourceAccessor" &&
      one(one(values(google_project_iam_member.database_operator_iap)).condition).expression == "destination.port == 22" &&
      one(values(google_service_account_iam_member.database_operator_act_as)).role == "roles/iam.serviceAccountUser" &&
      one(values(google_service_account_iam_member.database_operator_act_as)).service_account_id == google_service_account.runtime["database"].name &&
      google_project_iam_custom_role.database_release.permissions == toset([
        "compute.instanceGroupManagers.get",
        "compute.instanceGroupManagers.update",
        "compute.instances.setMetadata",
        "compute.snapshots.list",
        "compute.zoneOperations.get",
      ]) &&
      google_project_iam_member.database_release.member == "serviceAccount:infra-release@agora-management-test.iam.gserviceaccount.com" &&
      one(google_project_iam_member.database_release.condition).expression == "resource.type != 'compute.googleapis.com/Instance' || resource.name.startsWith('projects/agora-production-test/zones/europe-west1-c/instances/agora-database-')" &&
      alltrue([
        for permission in google_project_iam_custom_role.database_release.permissions :
        !startswith(permission, "compute.disks.") &&
        (!startswith(permission, "compute.instances.") || permission == "compute.instances.setMetadata") &&
        !startswith(permission, "compute.instanceTemplates.") &&
        (!startswith(permission, "compute.snapshots.") || permission == "compute.snapshots.list")
      ]) &&
      local.release_application_project_roles == toset([
        "roles/cloudscheduler.admin",
        "roles/cloudquotas.viewer",
      ]) &&
      length(google_project_iam_member.release_application) == 2 &&
      google_project_iam_custom_role.release_cloud_run_deployer.permissions == toset([
        "run.jobs.create",
        "run.jobs.createTagBinding",
        "run.jobs.delete",
        "run.jobs.deleteTagBinding",
        "run.jobs.get",
        "run.jobs.list",
        "run.jobs.listEffectiveTags",
        "run.jobs.listTagBindings",
        "run.jobs.update",
        "run.executions.get",
        "run.executions.list",
        "run.locations.list",
        "run.operations.get",
        "run.revisions.get",
        "run.revisions.list",
        "run.services.create",
        "run.services.createTagBinding",
        "run.services.delete",
        "run.services.deleteTagBinding",
        "run.services.get",
        "run.services.list",
        "run.services.listEffectiveTags",
        "run.services.listTagBindings",
        "run.services.update",
      ]) &&
      !contains(google_project_iam_custom_role.release_cloud_run_deployer.permissions, "run.jobs.run") &&
      !contains(google_project_iam_custom_role.release_cloud_run_deployer.permissions, "run.jobs.runWithOverrides") &&
      !contains(google_project_iam_custom_role.release_cloud_run_deployer.permissions, "run.jobs.setIamPolicy") &&
      !contains(google_project_iam_custom_role.release_cloud_run_deployer.permissions, "run.services.setIamPolicy") &&
      google_project_iam_member.release_cloud_run_deployer.member == "serviceAccount:infra-release@agora-management-test.iam.gserviceaccount.com" &&
      length(google_service_account_iam_member.release_runtime_act_as) == 5 &&
      toset(keys(google_service_account_iam_member.release_runtime_act_as)) == toset([
        "authentication",
        "backup",
        "json_keys",
        "restore",
        "scheduler_invoker",
      ]) &&
      alltrue([
        for binding in values(google_project_iam_member.release_application) :
        binding.role != "roles/secretmanager.secretAccessor"
      ]) &&
      length(google_storage_bucket_iam_member.backup_runtime_creator) == 1 &&
      google_storage_bucket_iam_member.backup_runtime_creator[0].bucket == "agora-management-test-123456789012-backups" &&
      google_storage_bucket_iam_member.backup_runtime_creator[0].role == "roles/storage.objectCreator" &&
      google_storage_bucket_iam_member.backup_runtime_creator[0].member == "serviceAccount:${google_service_account.runtime["backup"].email}" &&
      google_storage_bucket_iam_member.restore_runtime_viewer[0].role == "roles/storage.objectViewer" &&
      google_storage_bucket_iam_member.restore_runtime_viewer[0].member == "serviceAccount:${google_service_account.runtime["restore"].email}"
    )
    error_message = "Database runtime, operator, service-agent, or release IAM escaped its reviewed boundary."
  }

  assert {
    condition = (
      google_tags_tag_key.cloud_run_invocation.parent == "projects/987654321098" &&
      google_tags_tag_key.cloud_run_invocation.short_name == "agora-invocation" &&
      length(google_tags_tag_value.cloud_run_invocation) == 5 &&
      toset([for value in values(google_tags_tag_value.cloud_run_invocation) : value.short_name]) == toset([
        "initializer",
        "internal",
        "recovery",
        "release",
        "scheduled",
      ]) &&
      length(google_tags_tag_value_iam_member.release_tag_user) == 3 &&
      length(google_tags_tag_value_iam_member.initializer_tag_user) == 1 &&
      google_project_iam_member.release_cloud_run_invoker[0].role == "roles/run.jobsExecutor" &&
      strcontains(one(google_project_iam_member.release_cloud_run_invoker[0].condition).expression, "resource.matchTagId") &&
      google_project_iam_member.scheduler_cloud_run_invoker[0].role == "roles/run.jobsExecutor" &&
      google_project_iam_member.internal_cloud_run_invoker.role == "roles/run.servicesInvoker" &&
      google_project_iam_member.internal_cloud_run_invoker.member == "serviceAccount:${google_service_account.runtime["authentication"].email}" &&
      length(google_project_iam_member.recovery_cloud_run_invoker) == 0 &&
      length(google_project_iam_member.recovery_smoke_cloud_run_invoker) == 0 &&
      one(values(google_project_iam_member.initializer_cloud_run_invoker)).role == "roles/run.jobsExecutor" &&
      one(values(google_project_iam_member.initializer_cloud_run_invoker)).member == "group:authentication-initializers@example.com" &&
      one(values(google_service_account_iam_member.initializer_act_as)).service_account_id == google_service_account.runtime["authentication_initializer"].name &&
      google_project_iam_custom_role.authentication_initializer_deployer[0].permissions == toset([
        "run.executions.get",
        "run.executions.list",
        "run.jobs.create",
        "run.jobs.createTagBinding",
        "run.jobs.delete",
        "run.jobs.deleteTagBinding",
        "run.jobs.get",
        "run.jobs.list",
        "run.jobs.listEffectiveTags",
        "run.jobs.listTagBindings",
        "run.jobs.update",
        "run.locations.list",
        "run.operations.get",
      ]) &&
      !contains(google_project_iam_custom_role.authentication_initializer_deployer[0].permissions, "run.jobs.run") &&
      !contains(google_project_iam_custom_role.authentication_initializer_deployer[0].permissions, "run.jobs.runWithOverrides") &&
      !contains(google_project_iam_custom_role.authentication_initializer_deployer[0].permissions, "run.jobs.setIamPolicy") &&
      one(values(google_project_iam_member.authentication_initializer_deployer)).member == "group:authentication-initializers@example.com"
    )
    error_message = "Cloud Run tag classes must keep release, scheduler, runtime, recovery, and initializer invocation in separate least-privilege boundaries."
  }

  assert {
    condition = (
      length(google_monitoring_alert_policy.database_capacity) == 5 &&
      {
        for name, policy in google_monitoring_alert_policy.database_capacity :
        name => one(policy.conditions).condition_threshold[0].threshold_value
        } == {
        cpu_sustained   = 0.70
        disk_critical   = 85
        disk_warning    = 70
        memory_critical = 85
        memory_warning  = 70
      } &&
      alltrue([
        for policy in values(google_monitoring_alert_policy.database_capacity) :
        policy.deletion_policy == "PREVENT" &&
        strcontains(one(policy.conditions).condition_threshold[0].filter, "resource.label.zone = \"europe-west1-c\"") &&
        strcontains(one(policy.conditions).condition_threshold[0].filter, "metric.label.instance_name = starts_with(\"agora-database-\")") &&
        toset(policy.notification_channels) == toset([google_monitoring_notification_channel.operations_email[0].name]) &&
        one(policy.conditions).condition_threshold[0].trigger[0].count == 1
      ])
    )
    error_message = "The database capacity alert set, thresholds, or stable instance-name selector changed."
  }

  assert {
    condition = (
      google_compute_resource_policy.database_snapshots.region == "europe-west1" &&
      one(google_compute_resource_policy.database_snapshots.snapshot_schedule_policy).schedule[0].daily_schedule[0].days_in_cycle == 1 &&
      one(google_compute_resource_policy.database_snapshots.snapshot_schedule_policy).schedule[0].daily_schedule[0].start_time == "02:00" &&
      one(google_compute_resource_policy.database_snapshots.snapshot_schedule_policy).retention_policy[0].max_retention_days == 7 &&
      one(google_compute_resource_policy.database_snapshots.snapshot_schedule_policy).retention_policy[0].on_source_disk_delete == "KEEP_AUTO_SNAPSHOTS" &&
      !one(google_compute_resource_policy.database_snapshots.snapshot_schedule_policy).snapshot_properties[0].guest_flush &&
      toset(one(google_compute_resource_policy.database_snapshots.snapshot_schedule_policy).snapshot_properties[0].storage_locations) == toset(["europe-west1"]) &&
      google_compute_disk_resource_policy_attachment.database_snapshots.disk == google_compute_disk.database.name &&
      google_monitoring_alert_policy.postgres_recovery_job_failure[0].severity == "CRITICAL" &&
      google_monitoring_alert_policy.postgres_recovery_job_failure[0].deletion_policy == "PREVENT" &&
      toset(google_monitoring_alert_policy.postgres_recovery_job_failure[0].notification_channels) == toset([google_monitoring_notification_channel.operations_email[0].name]) &&
      length(google_monitoring_alert_policy.postgres_recovery_job_failure[0].conditions) == 2 &&
      strcontains(one([
        for condition in google_monitoring_alert_policy.postgres_recovery_job_failure[0].conditions : condition
        if length(condition.condition_threshold) == 1
      ]).condition_threshold[0].filter, "run.googleapis.com/job/completed_execution_count") &&
      strcontains(one([
        for condition in google_monitoring_alert_policy.postgres_recovery_job_failure[0].conditions : condition
        if length(condition.condition_threshold) == 1
      ]).condition_threshold[0].filter, "metric.label.result = \"failed\"") &&
      strcontains(one([
        for condition in google_monitoring_alert_policy.postgres_recovery_job_failure[0].conditions : condition
        if length(condition.condition_threshold) == 1
      ]).condition_threshold[0].filter, "agora-postgres-") &&
      one([
        for condition in google_monitoring_alert_policy.postgres_recovery_job_failure[0].conditions : condition
        if length(condition.condition_absent) == 1
      ]).condition_absent[0].duration == "10800s" &&
      strcontains(one([
        for condition in google_monitoring_alert_policy.postgres_recovery_job_failure[0].conditions : condition
        if length(condition.condition_absent) == 1
      ]).condition_absent[0].filter, "resource.label.job_name = \"agora-postgres-backup-monitor\"") &&
      !strcontains(one([
        for condition in google_monitoring_alert_policy.postgres_recovery_job_failure[0].conditions : condition
        if length(condition.condition_absent) == 1
      ]).condition_absent[0].filter, "metric.label.result") &&
      one([
        for condition in google_monitoring_alert_policy.postgres_recovery_job_failure[0].conditions : condition
        if length(condition.condition_absent) == 1
      ]).condition_absent[0].trigger[0].count == 1
    )
    error_message = "Same-region snapshot storage or native failed/missing recovery-job alerting changed."
  }

  assert {
    condition = (
      length(google_monitoring_alert_policy.authentication_error_rate) == 1 &&
      google_monitoring_alert_policy.authentication_error_rate[0].severity == "ERROR" &&
      toset(google_monitoring_alert_policy.authentication_error_rate[0].notification_channels) == toset([google_monitoring_notification_channel.operations_email[0].name]) &&
      one(google_monitoring_alert_policy.authentication_error_rate[0].conditions).condition_threshold[0].threshold_value == 0.10 &&
      one(google_monitoring_alert_policy.authentication_error_rate[0].conditions).condition_threshold[0].duration == "300s" &&
      strcontains(one(google_monitoring_alert_policy.authentication_error_rate[0].conditions).condition_threshold[0].filter, "metric.label.response_code_class = \"5xx\"") &&
      strcontains(one(google_monitoring_alert_policy.authentication_error_rate[0].conditions).condition_threshold[0].denominator_filter, "agora-authentication-rest") &&
      length(google_monitoring_alert_policy.application_jobs_unhealthy) == 1 &&
      length(google_monitoring_alert_policy.application_jobs_unhealthy[0].conditions) == 2 &&
      strcontains(one([
        for condition in google_monitoring_alert_policy.application_jobs_unhealthy[0].conditions : condition
        if length(condition.condition_threshold) == 1
      ]).condition_threshold[0].filter, "agora-authentication-") &&
      strcontains(one([
        for condition in google_monitoring_alert_policy.application_jobs_unhealthy[0].conditions : condition
        if length(condition.condition_threshold) == 1
      ]).condition_threshold[0].filter, "agora-json-keys-") &&
      one([
        for condition in google_monitoring_alert_policy.application_jobs_unhealthy[0].conditions : condition
        if length(condition.condition_absent) == 1
      ]).condition_absent[0].duration == "10800s" &&
      strcontains(one([
        for condition in google_monitoring_alert_policy.application_jobs_unhealthy[0].conditions : condition
        if length(condition.condition_absent) == 1
      ]).condition_absent[0].filter, "metric.label.result = \"succeeded\"")
    )
    error_message = "Authentication 5xx, application-job failure, and missed JSON Keys rotation policies changed."
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
      google_artifact_registry_repository_iam_member.database_reader.member == "serviceAccount:${google_service_account.runtime["database"].email}" &&
      one(values(google_artifact_registry_repository_iam_member.authentication_initializer_reader)).member == "group:authentication-initializers@example.com"
    )
    error_message = "The immutable regional registry, dry-run cleanup policy, or write/read split changed."
  }

  assert {
    condition = (
      length(google_cloud_quotas_quota_preference.cost_cap) == 3 &&
      alltrue([
        for preference in values(google_cloud_quotas_quota_preference.cost_cap) :
        preference.dimensions == tomap({ region = "europe-west1" }) &&
        preference.contact_email == "infra@example.com" &&
        preference.ignore_safety_checks == "QUOTA_DECREASE_PERCENTAGE_TOO_HIGH"
      ]) &&
      google_cloud_quotas_quota_preference.cost_cap["cloud_run_cpu"].service == "run.googleapis.com" &&
      local.quota_preferences["cloud_run_cpu"].metric == "run.googleapis.com/cpu_allocation" &&
      local.quota_preferences["cloud_run_memory"].metric == "run.googleapis.com/mem_allocation" &&
      google_cloud_quotas_quota_preference.cost_cap["compute_cpu"].service == "compute.googleapis.com" &&
      local.quota_preferences["compute_cpu"].metric == "compute.googleapis.com/cpus" &&
      google_cloud_quotas_quota_preference.cost_cap["cloud_run_cpu"].quota_config[0].preferred_value == "8000" &&
      google_cloud_quotas_quota_preference.cost_cap["cloud_run_memory"].quota_config[0].preferred_value == "17179869184" &&
      google_cloud_quotas_quota_preference.cost_cap["compute_cpu"].quota_config[0].preferred_value == "4"
    )
    error_message = "The regional quota contact, safety bypass, or explicit cost ceilings changed."
  }

  assert {
    condition = (
      length(google_monitoring_notification_channel.cost_email) == 1 &&
      google_monitoring_notification_channel.cost_email[0].type == "email" &&
      google_monitoring_notification_channel.cost_email[0].enabled &&
      google_monitoring_notification_channel.cost_email[0].labels == tomap({ email_address = "infra@example.com" }) &&
      google_monitoring_notification_channel.cost_email[0].deletion_policy == "PREVENT" &&
      length(google_monitoring_notification_channel.operations_email) == 1 &&
      google_monitoring_notification_channel.operations_email[0].labels == tomap({ email_address = "operations@example.com" }) &&
      google_monitoring_notification_channel.operations_email[0].deletion_policy == "PREVENT" &&
      length(data.google_billing_account.workload) == 1 &&
      length(data.google_project.management) == 1 &&
      length(google_billing_budget.workload) == 1 &&
      google_billing_budget.workload[0].amount[0].specified_amount[0].units == "60" &&
      google_billing_budget.workload[0].amount[0].specified_amount[0].currency_code == "EUR" &&
      toset(google_billing_budget.workload[0].budget_filter[0].projects) == toset([
        "projects/123456789012",
        "projects/987654321098",
      ]) &&
      toset([
        for threshold in google_billing_budget.workload[0].threshold_rules :
        "${threshold.spend_basis}:${threshold.threshold_percent}"
        ]) == toset([
        "CURRENT_SPEND:0.5",
        "CURRENT_SPEND:0.75",
        "CURRENT_SPEND:0.9",
        "CURRENT_SPEND:1",
        "FORECASTED_SPEND:0.5",
        "FORECASTED_SPEND:0.75",
        "FORECASTED_SPEND:0.9",
        "FORECASTED_SPEND:1",
      ]) &&
      google_billing_budget.workload[0].all_updates_rule[0].disable_default_iam_recipients &&
      !google_billing_budget.workload[0].all_updates_rule[0].enable_project_level_recipients &&
      length(google_billing_budget.workload[0].all_updates_rule[0].monitoring_notification_channels) == 2 &&
      google_logging_project_bucket_config.default.retention_days == 30 &&
      strcontains(google_logging_project_exclusion.successful_healthchecks.filter, "httpRequest.status>=200") &&
      strcontains(google_logging_project_exclusion.successful_healthchecks.filter, "resource.labels.service_name=\"agora-authentication-rest\"") &&
      strcontains(google_logging_project_exclusion.successful_healthchecks.filter, "ping|healthcheck") &&
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

run "rejects_an_invalid_operations_email" {
  command = plan

  variables {
    operations_alert_email = "not-an-email"
  }

  expect_failures = [var.operations_alert_email]
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

run "rejects_creating_a_parentless_project" {
  command = plan

  variables {
    organization_id = null
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

run "rejects_a_database_zone_outside_the_region" {
  command = plan

  variables {
    database_zone = "us-central1-a"
  }

  expect_failures = [check.database_zone_matches_region]
}

run "rejects_database_memory_without_host_headroom" {
  command = plan

  variables {
    database_container_memory_mb = 2048
  }

  expect_failures = [check.database_container_memory_headroom]
}

run "rejects_database_cpu_without_host_headroom" {
  command = plan

  variables {
    database_container_cpu = 1
  }

  expect_failures = [check.database_container_cpu_headroom]
}

run "rejects_an_unreviewed_database_machine" {
  command = plan

  variables {
    database_machine_type = "n2-standard-8"
  }

  expect_failures = [var.database_machine_type]
}

run "rejects_a_non_incremental_database_disk_size" {
  command = plan

  variables {
    database_data_disk_size_gb = 55
  }

  expect_failures = [var.database_data_disk_size_gb]
}

run "rejects_a_non_human_database_operator" {
  command = plan

  variables {
    database_operator_principals = [
      "serviceAccount:debug@example.iam.gserviceaccount.com",
    ]
  }

  expect_failures = [var.database_operator_principals]
}

run "limits_disposable_recovery_authority_to_the_replacement_project" {
  command = plan

  variables {
    recovery_mode = true
  }

  assert {
    condition = (
      alltrue([
        for binding in values(google_project_iam_member.foundation) :
        binding.member == "serviceAccount:infra-recovery@agora-management-test.iam.gserviceaccount.com"
      ]) &&
      !contains(local.foundation_project_roles, "roles/monitoring.alertPolicyEditor") &&
      !contains(local.foundation_project_roles, "roles/monitoring.notificationChannelEditor") &&
      google_project_iam_member.foundation_project_metadata.member == "serviceAccount:infra-recovery@agora-management-test.iam.gserviceaccount.com" &&
      length(google_project_iam_member.recovery_project_deleter) == 1 &&
      google_project_iam_member.recovery_project_deleter[0].role == "roles/resourcemanager.projectDeleter" &&
      google_project_iam_member.recovery_project_deleter[0].member == "serviceAccount:infra-recovery@agora-management-test.iam.gserviceaccount.com" &&
      google_service_account_iam_member.foundation_database_act_as.member == "serviceAccount:infra-recovery@agora-management-test.iam.gserviceaccount.com" &&
      alltrue([
        for binding in values(google_service_account_iam_member.release_runtime_act_as) :
        binding.member == "serviceAccount:infra-recovery@agora-management-test.iam.gserviceaccount.com"
      ]) &&
      alltrue([
        for binding in values(google_project_iam_member.release_application) :
        binding.member == "serviceAccount:infra-recovery@agora-management-test.iam.gserviceaccount.com"
      ]) &&
      google_project_iam_member.release_cloud_run_deployer.member == "serviceAccount:infra-recovery@agora-management-test.iam.gserviceaccount.com" &&
      google_project_iam_member.database_release.member == "serviceAccount:infra-recovery@agora-management-test.iam.gserviceaccount.com" &&
      google_artifact_registry_repository_iam_member.release_writer.member == "serviceAccount:infra-recovery@agora-management-test.iam.gserviceaccount.com" &&
      length(google_compute_network.default_adoption) == 0 &&
      length(google_project_iam_member.plan_viewer) == 0 &&
      length(google_artifact_registry_repository_iam_member.recovery_reader) == 0 &&
      length(google_artifact_registry_repository_iam_member.authentication_initializer_reader) == 0 &&
      toset(keys(google_service_account_iam_member.release_runtime_act_as)) == toset([
        "authentication",
        "json_keys",
        "restore",
      ]) &&
      length(google_tags_tag_value_iam_member.release_tag_user) == 2 &&
      length(google_tags_tag_value_iam_member.initializer_tag_user) == 0 &&
      length(google_project_iam_member.release_cloud_run_invoker) == 0 &&
      length(google_project_iam_member.scheduler_cloud_run_invoker) == 0 &&
      length(google_project_iam_member.recovery_cloud_run_invoker) == 1 &&
      google_project_iam_member.recovery_cloud_run_invoker[0].role == "roles/run.jobsExecutor" &&
      length(google_project_iam_member.recovery_smoke_cloud_run_invoker) == 1 &&
      google_project_iam_member.recovery_smoke_cloud_run_invoker[0].role == "roles/run.servicesInvoker" &&
      length(google_project_iam_member.initializer_cloud_run_invoker) == 0 &&
      length(google_service_account_iam_member.initializer_act_as) == 0 &&
      length(google_project_iam_custom_role.authentication_initializer_deployer) == 0 &&
      length(google_project_iam_member.authentication_initializer_deployer) == 0 &&
      local.release_application_project_roles == toset(["roles/cloudquotas.viewer"])
    )
    error_message = "A replacement project must grant every automation boundary only to recovery, never production foundation or release."
  }

  assert {
    condition = (
      contains(google_compute_firewall.allow_postgres_egress["authentication"].target_tags, "agora-restore") &&
      contains(google_compute_firewall.allow_postgres_egress["json_keys"].target_tags, "agora-restore") &&
      contains(keys(local.runtime_secret_access), "restore:authentication-owner-password") &&
      contains(keys(local.runtime_secret_access), "restore:json-keys-owner-password") &&
      length(google_secret_manager_secret_iam_member.runtime) == 0 &&
      length(google_storage_bucket_iam_member.backup_runtime_creator) == 0 &&
      length(google_storage_bucket_iam_member.restore_runtime_viewer) == 0
    )
    error_message = "Recovery CI must create no management-plane secret or backup-payload IAM binding; the exact contract is human-applied."
  }

  assert {
    condition = (
      length(google_monitoring_notification_channel.cost_email) == 0 &&
      length(google_monitoring_notification_channel.operations_email) == 0 &&
      length(data.google_billing_account.workload) == 0 &&
      length(data.google_project.management) == 0 &&
      length(google_billing_budget.workload) == 0 &&
      length(google_monitoring_alert_policy.authentication_error_rate) == 0 &&
      length(google_monitoring_alert_policy.application_jobs_unhealthy) == 0 &&
      length(google_monitoring_alert_policy.database_capacity) == 0 &&
      length(google_monitoring_alert_policy.postgres_recovery_job_failure) == 0
    )
    error_message = "A short-lived recovery project must not duplicate production budgets, notification channels, or alert policies."
  }
}

run "rejects_a_non_human_authentication_initializer" {
  command = plan

  variables {
    authentication_initializer_principals = [
      "serviceAccount:automation@agora-management-test.iam.gserviceaccount.com",
    ]
  }

  expect_failures = [var.authentication_initializer_principals]
}
