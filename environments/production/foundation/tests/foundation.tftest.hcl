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
  # A peering checks that both networks are well-formed.
  mock_resource "google_compute_network" {
    defaults = { id = "projects/a-novel-production-prod/global/networks/mock" }
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

run "resolves_only_the_dns_allowlist" {
  command = plan

  assert {
    condition = (
      contains(keys(google_dns_response_policy_rule.deny), "*.") &&
      alltrue([for records in [for rule in google_dns_response_policy_rule.deny : one(rule.local_data).local_datas] :
        length(records) == 1 && one(records).type == "CNAME" && one(one(records).rrdatas) == "blocked.internal."
      ])
    )
    error_message = "The DNS allowlist must refuse every name below the root, with a CNAME that answers every record type."
  }

  assert {
    condition = alltrue([for name in keys(google_dns_response_policy_rule.allow) :
      !startswith(name, "*.") || contains(local.dns_google_domains, trimprefix(name, "*."))
    ])
    error_message = "Only a domain Google answers inside, a private zone or internal DNS, may be allowed whole. A public host is allowed by its exact name."
  }

  assert {
    condition = alltrue(concat(
      [for rule in google_compute_network_firewall_policy_rule.egress_allowlist :
        alltrue([for fqdn in coalesce(rule.match[0].dest_fqdns, []) : contains(keys(google_dns_response_policy_rule.allow), "${fqdn}.")])
      ],
      [for zone in concat([google_dns_managed_zone.googleapis], values(google_dns_managed_zone.private_google_domain)) :
        contains(keys(google_dns_response_policy_rule.allow), zone.dns_name) &&
        contains(keys(google_dns_response_policy_rule.allow), "*.${zone.dns_name}")
      ],
    ))
    error_message = "The firewall resolves its hosts through the DNS allowlist, and the private zones answer their whole domains, so each must be allowed."
  }
}

run "fences_the_cluster_network" {
  command = plan

  # Mocks give every network and subnet the same generated ID, which would hide which one a binding
  # names.
  override_resource {
    target = google_compute_network.production
    values = { id = "projects/a-novel-production-prod/global/networks/agora-production" }
  }

  override_resource {
    target = google_compute_network.cluster
    values = { id = "projects/a-novel-production-prod/global/networks/a-novel-production" }
  }

  override_resource {
    target = google_compute_subnetwork.cluster
    values = { id = "projects/a-novel-production-prod/regions/europe-west9/subnetworks/a-novel-production-europe-west9" }
  }

  assert {
    condition = (
      google_compute_firewall.cluster_deny_other_egress.destination_ranges == toset(["0.0.0.0/0"]) &&
      google_compute_firewall.cluster_deny_other_egress.target_tags == null &&
      alltrue([for rule in [google_compute_firewall.cluster_allow_restricted_google_apis, google_compute_firewall.cluster_allow_internal_egress] :
        rule.priority < google_compute_firewall.cluster_deny_other_egress.priority
      ])
    )
    error_message = "A network-wide deny must sit below every explicit egress allow of the cluster's network."
  }

  assert {
    condition = (
      keys(google_compute_network_firewall_policy_rule.cluster_egress_allowlist) == keys(local.egress_allowlist) &&
      alltrue([for key, rule in google_compute_network_firewall_policy_rule.egress_allowlist :
        google_compute_network_firewall_policy_rule.cluster_egress_allowlist[key].match == rule.match &&
        google_compute_network_firewall_policy_rule.cluster_egress_allowlist[key].action == "allow"
      ])
    )
    error_message = "The cluster's nodes may reach exactly the egress allowlist's destinations."
  }

  assert {
    condition     = [for subnet in google_compute_router_nat.cluster.subnetwork : subnet.name] == [google_compute_subnetwork.cluster.id]
    error_message = "The cluster's Cloud NAT must serve the cluster's subnet alone."
  }

  assert {
    condition = alltrue([for networks in concat(
      [google_dns_policy.production.networks, google_dns_response_policy.allowlist.networks],
      [for zone in concat([google_dns_managed_zone.googleapis], values(google_dns_managed_zone.private_google_domain)) : one(zone.private_visibility_config).networks],
    ) : toset([for network in networks : network.network_url]) == toset([google_compute_network.production.id, google_compute_network.cluster.id])])
    error_message = "Both networks must log their lookups, resolve through the private zones and resolve only the DNS allowlist."
  }

  assert {
    condition = alltrue([for pair in setproduct(values(var.cluster_ranges), [var.subnet_cidr, var.egress_subnet_cidr]) :
      !cidrcontains(pair[0], cidrhost(pair[1], 0)) && !cidrcontains(pair[1], cidrhost(pair[0], 0))
    ])
    error_message = "The peered networks' ranges must not overlap."
  }

  # The hosts' addresses are known only once their groups exist, so the egress rule's destination
  # stays unknown here.
  assert {
    condition = alltrue([for service, host in local.database_hosts : (
      google_compute_firewall.allow_database_imports[service].source_ranges == toset([var.cluster_ranges.pods]) &&
      google_compute_firewall.allow_database_imports[service].target_tags == toset([local.network_tags[host.identity]]) &&
      alltrue([for rule in concat(tolist(google_compute_firewall.allow_database_imports[service].allow), tolist(google_compute_firewall.cluster_allow_database_imports[service].allow)) : rule.protocol == "tcp" && rule.ports == tolist([tostring(host.port)])])
    )])
    error_message = "The import must open each database host to the cluster's pods on that host's port alone."
  }
}

run "holds_cluster_upgrades_during_a_planned_downtime" {
  command = plan

  variables {
    downtime = "{\"components\":[\"service-json-keys.database\"],\"start\":\"2026-11-10T22:00:00Z\",\"end\":\"2026-11-11T00:00:00Z\"}"
  }

  assert {
    condition = (
      one(one(google_container_cluster.production.maintenance_policy).maintenance_exclusion).start_time == "2026-11-10T22:00:00Z" &&
      one(one(google_container_cluster.production.maintenance_policy).maintenance_exclusion).end_time == "2026-11-11T00:00:00Z"
    )
    error_message = "A planned downtime must hold every cluster upgrade from its start to its end."
  }
}

run "keeps_the_cluster_private" {
  command = plan

  assert {
    condition = (
      one(google_container_cluster.production.private_cluster_config).enable_private_nodes &&
      one(google_container_cluster.production.private_cluster_config).enable_private_endpoint &&
      one(one(google_container_cluster.production.control_plane_endpoints_config).dns_endpoint_config).allow_external_traffic
    )
    error_message = "Nodes must have no external address, and the control plane must answer outside the network only through its DNS endpoint."
  }

  assert {
    condition = (
      one(google_container_cluster.production.workload_identity_config).workload_pool == "${google_project.workload.project_id}.svc.id.goog" &&
      one(one(google_container_node_pool.general.node_config).workload_metadata_config).mode == "GKE_METADATA" &&
      one(google_container_node_pool.general.node_config).service_account == google_service_account.runtime["cluster_nodes"].email &&
      one(one(google_container_node_pool.general.node_config).shielded_instance_config).enable_secure_boot
    )
    error_message = "Pods must get their own identities through GKE's metadata server, and nodes must boot securely as the node identity, never the default one."
  }

  assert {
    condition = (
      google_container_cluster.production.deletion_protection &&
      one(google_container_cluster.production.release_channel).channel != "UNSPECIFIED" &&
      !one(one(google_container_cluster.production.monitoring_config).managed_prometheus).enabled
    )
    error_message = "The cluster must refuse deletion, upgrade on a release channel, and leave metrics to Grafana."
  }

  assert {
    condition = (
      google_artifact_registry_repository.studio.project == google_project.workload.project_id &&
      one(google_artifact_registry_repository.studio.docker_config).immutable_tags &&
      google_artifact_registry_repository_iam_member.cluster_studio.role == "roles/artifactregistry.reader" &&
      google_artifact_registry_repository_iam_member.cluster_studio.member == google_service_account.runtime["cluster_nodes"].member
    )
    error_message = "Studio's cluster release must sit in the workload project, which admission requires, with immutable tags the nodes only read."
  }

  assert {
    condition = (
      google_artifact_registry_repository.narrative_engine.project == google_project.workload.project_id &&
      one(google_artifact_registry_repository.narrative_engine.docker_config).immutable_tags &&
      google_artifact_registry_repository_iam_member.cluster_narrative_engine.role == "roles/artifactregistry.reader" &&
      google_artifact_registry_repository_iam_member.cluster_narrative_engine.member == google_service_account.runtime["cluster_nodes"].member
    )
    error_message = "narrative-engine's cluster release must sit in the workload project, which admission requires, with immutable tags the nodes only read."
  }
}

run "grants_no_basic_roles" {
  command = plan

  assert {
    condition = alltrue([for binding in concat(values(google_project_iam_member.foundation), values(google_project_iam_member.database_operator), values(google_project_iam_member.database_operator_public_api_logs)) :
      !contains(["roles/owner", "roles/editor"], binding.role)
    ])
    error_message = "Automation and operators get scoped roles, never owner or editor."
  }

  assert {
    condition = (
      alltrue([for principal in var.database_operator_principals : google_project_iam_member.database_operator["${principal}:roles/container.clusterViewer"].role == "roles/container.clusterViewer"]) &&
      [for binding in values(google_project_iam_member.database_operator) : binding.role if startswith(binding.role, "roles/container.")] == [for principal in var.database_operator_principals : "roles/container.clusterViewer"]
    )
    error_message = "Operators may only connect to the cluster through IAM; the cluster root's RBAC decides what they read."
  }

  assert {
    condition     = !google_cloud_scheduler_job.json_keys_rotation[0].paused
    error_message = "Key rotation must stay scheduled."
  }

  assert {
    condition = (
      !google_cloud_scheduler_job.authentication_refresh_token_purge[0].paused &&
      google_tags_location_tag_binding.application["authentication_refresh_token_purge"].tag_value == google_tags_tag_value.cloud_run_invocation["scheduled"].id
    )
    error_message = "The refresh token purge must stay scheduled, and tagged so the scheduler may run it without overrides."
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
      !google_access_context_manager_service_perimeter.production.use_explicit_dry_run_spec &&
      length(google_access_context_manager_service_perimeter.production.status) == 1 &&
      length(google_access_context_manager_service_perimeter.production.spec) == 0
    )
    error_message = "The perimeter must enforce its rules as its status, with no dry-run spec of its own."
  }

  assert {
    condition = (
      one(google_access_context_manager_service_perimeter.production.status[0].vpc_accessible_services).enable_restriction &&
      one(google_access_context_manager_service_perimeter.production.status[0].vpc_accessible_services).allowed_services == toset(["RESTRICTED-SERVICES"]) &&
      alltrue([for service in concat(keys(google_project_service.workload), keys(google_project_service.public_api_telemetry)) :
        contains(google_access_context_manager_service_perimeter.production.status[0].restricted_services, service)
      ])
    )
    error_message = "The VPC may call only the perimeter's restricted APIs, and every API the projects enable must be restricted."
  }

  assert {
    condition = (
      alltrue([for rule in google_access_context_manager_service_perimeter.production.status[0].ingress_policies :
        rule.ingress_from[0].identity_type == null && length(rule.ingress_from[0].identities) > 0
      ]) &&
      alltrue([for rule in google_access_context_manager_service_perimeter.production.status[0].egress_policies :
        rule.egress_to[0].resources == toset(["projects/${data.google_project.management.number}"])
      ])
    )
    error_message = "Only named identities may enter the perimeter, and calls may leave it only for the management project."
  }
}

run "alerts_at_each_budget_share" {
  command = plan

  assert {
    condition = alltrue([for basis in ["CURRENT_SPEND", "FORECASTED_SPEND"] :
      sort([for rule in google_billing_budget.workload.threshold_rules : tostring(rule.threshold_percent) if rule.spend_basis == basis]) == sort(["0.5", "0.75", "0.8", "0.9", "1"])
    ])
    error_message = "The budget alerts at 50, 75, 80, 90 and 100%, for both the spend so far and the month's forecast."
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

run "serves_studio_on_its_host" {
  command = plan

  assert {
    condition = (
      one(google_container_cluster.production.gateway_api_config).channel == "CHANNEL_STANDARD" &&
      google_compute_ssl_policy.studio.profile == "MODERN" &&
      google_compute_ssl_policy.studio.min_tls_version == "TLS_1_2"
    )
    error_message = "The cluster must run the Gateway API, and Studio's edge must refuse TLS below 1.2."
  }

  assert {
    condition = (
      one(google_certificate_manager_certificate.studio.managed).domains == tolist([output.studio_edge.host]) &&
      length(one(google_certificate_manager_certificate.studio.managed).dns_authorizations) == 1 &&
      google_certificate_manager_dns_authorization.studio.domain == output.studio_edge.host &&
      google_certificate_manager_certificate_map_entry.studio.hostname == output.studio_edge.host &&
      google_certificate_manager_certificate_map_entry.studio.map == output.studio_edge.certificate_map &&
      contains(keys(google_project_iam_member.foundation), "roles/certificatemanager.editor")
    )
    error_message = "Studio's certificate must cover only its host, authorized by DNS, and its map must serve it for that host, which the deploy identity may create."
  }
}

run "lets_maintenance_operators_reach_the_cluster" {
  command = plan

  assert {
    condition = (
      alltrue([for principal in var.authentication_maintenance_principals : google_project_iam_member.maintenance_observer["${principal}:roles/container.clusterViewer"].project == google_project.workload.project_id]) &&
      [for binding in values(google_project_iam_member.maintenance_observer) : binding.role if startswith(binding.role, "roles/container.")] == [for principal in var.authentication_maintenance_principals : "roles/container.clusterViewer"]
    )
    error_message = "Maintenance operators may only connect to the cluster through IAM; the cluster root's RBAC decides what they run."
  }
}
