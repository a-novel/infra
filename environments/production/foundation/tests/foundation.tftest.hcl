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

  assert {
    condition = (
      alltrue([for template in google_compute_instance_template.database :
        template.project == google_logging_project_exclusion.database_health_probes.project
      ]) &&
      strcontains(google_logging_project_exclusion.database_health_probes.filter, "exitCode=0,")
    )
    error_message = "Only successful database health probes are excluded, in the project the database hosts log to."
  }
}

run "denies_everything_the_network_does_not_allow" {
  command = plan

  # Mocks give both subnets the same generated ID, which would hide the subnet NAT serves.
  override_resource {
    target = google_compute_subnetwork.production
    values = { id = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-europe-west1" }
  }

  override_resource {
    target = google_compute_subnetwork.egress
    values = { id = "projects/a-novel-production-prod/regions/europe-west1/subnetworks/agora-production-egress-europe-west1" }
  }

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
    condition = alltrue([for rule in google_compute_network_firewall_policy_rule.egress_allowlist :
      rule.direction == "EGRESS" && rule.action == "allow" && length(rule.target_service_accounts) > 0 &&
      rule.match[0].dest_ip_ranges == null &&
      (length(coalesce(rule.match[0].dest_fqdns, [])) > 0) != (length(coalesce(rule.match[0].dest_address_groups, [])) > 0) &&
      alltrue([for layer4 in rule.match[0].layer4_configs : layer4.ip_protocol == "tcp" && length(layer4.ports) == 1])
    ])
    error_message = "The egress allowlist may only let named identities reach named hosts, or one address group, on one TCP port. Everything else must fall through to the deny."
  }

  assert {
    condition = (
      one(google_compute_network_firewall_policy_rule.egress_allowlist["smtp-relay"].match[0].dest_address_groups) == google_network_security_address_group.google_services.id &&
      alltrue([for range in google_network_security_address_group.google_services.items :
        can(cidrhost(range, 0)) && tonumber(split("/", range)[1]) >= 8
      ])
    )
    error_message = "SMTP may reach only Google's service ranges, each a valid IPv4 CIDR no wider than a /8."
  }

  assert {
    condition = (
      google_compute_firewall.allow_iap_ssh.source_ranges == toset(["35.235.240.0/20"]) &&
      alltrue([for rule in google_compute_firewall.allow_postgres_ingress : rule.source_ranges == toset([var.subnet_cidr, var.egress_subnet_cidr])])
    )
    error_message = "SSH must come only from Identity-Aware Proxy, and PostgreSQL only from the two private subnets."
  }

  assert {
    condition = (
      google_compute_router_nat.production.source_subnetwork_ip_ranges_to_nat == "LIST_OF_SUBNETWORKS" &&
      [for subnet in google_compute_router_nat.production.subnetwork : subnet.name] == [google_compute_subnetwork.egress.id]
    )
    error_message = "Cloud NAT must serve the egress subnet alone, never the VMs' subnet."
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

run "keeps_humans_off_untagged_jobs" {
  command = plan

  assert {
    condition = alltrue([for binding in google_project_iam_member.maintenance_operator :
      binding.role == "roles/run.jobsExecutorWithOverrides" && length(binding.condition) == 1
    ])
    error_message = "Humans may run with arguments only the job tagged maintenance."
  }
}

run "copies_and_pins_host_credentials_by_digest" {
  command = plan

  assert {
    condition = alltrue([for service in ["json-keys", "authentication"] : contains(output.image_copies, {
      source   = var.host_credentials_image
      producer = "a-novel/infra"
      workflow = "publish-rollout-verifier.yaml"
      target   = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-${service}-private-tooling/host-credentials:${regex(":([^@]+)@", var.host_credentials_image)[0]}"
    })])
    error_message = "Deploy must verify host-credentials against its publication workflow and copy it into each service's tooling repository."
  }

  assert {
    condition = alltrue([for key, service in { json_keys = "json-keys", authentication = "authentication" } :
      output.database_hosts[key].credentials_image == "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-${service}-private-tooling/host-credentials@${regex("@(sha256:[0-9a-f]{64})$", var.host_credentials_image)[0]}"
    ])
    error_message = "Each database host must run host-credentials from its service's tooling repository, by digest."
  }
}

run "keeps_api_calls_inside_production" {
  command = plan

  assert {
    condition = (
      one(google_access_context_manager_service_perimeter.production.spec[0].vpc_accessible_services).enable_restriction &&
      one(google_access_context_manager_service_perimeter.production.spec[0].vpc_accessible_services).allowed_services == toset(["RESTRICTED-SERVICES"]) &&
      alltrue([for service in concat(keys(google_project_service.workload), keys(google_project_service.public_api_telemetry)) :
        contains(google_access_context_manager_service_perimeter.production.spec[0].restricted_services, service)
      ])
    )
    error_message = "The VPC may call only the perimeter's restricted APIs, and every API the projects enable must be restricted."
  }

  assert {
    condition = (
      alltrue([for rule in google_access_context_manager_service_perimeter.production.spec[0].ingress_policies :
        rule.ingress_from[0].identity_type == null && length(rule.ingress_from[0].identities) > 0
      ]) &&
      alltrue([for rule in google_access_context_manager_service_perimeter.production.spec[0].egress_policies :
        rule.egress_to[0].resources == toset(["projects/${data.google_project.management.number}"])
      ])
    )
    error_message = "Only named identities may enter the perimeter, and calls may leave it only for the management project."
  }
}

run "caps_cloud_run_in_every_project" {
  command = plan

  assert {
    condition = alltrue([for project in concat(["cloud_run"], [for zone in ["public", "public-api"] : "${zone}/cloud_run"]) :
      google_cloud_quotas_quota_preference.cost_cap["${project}_cpu"].quota_id == "CpuAllocPerProjectRegion" &&
      google_cloud_quotas_quota_preference.cost_cap["${project}_memory"].quota_id == "MemAllocPerProjectRegion"
    ])
    error_message = "Every project that runs Cloud Run services needs a CPU and a memory ceiling."
  }
}
