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
  mock_resource "google_compute_network" {
    defaults = { id = "projects/a-novel-production-prod/global/networks/mock" }
  }
  mock_data "google_project" {
    defaults = { number = "232403541574" }
  }
}

# Tests cannot import.
variables {
  orphan_addresses = {}
  orphan_snapshots = {}
}

mock_provider "google-beta" {
  mock_resource "google_project_service_identity" {
    defaults = { member = "serviceAccount:mock-agent@gcp-sa-cloudscheduler.iam.gserviceaccount.com" }
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
      [for rule in google_compute_network_firewall_policy_rule.cluster_egress_allowlist :
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
      alltrue([for rule in google_compute_network_firewall_policy_rule.cluster_egress_allowlist :
        rule.direction == "EGRESS" && rule.action == "allow" && rule.match[0].dest_ip_ranges == null &&
        (length(coalesce(rule.match[0].dest_fqdns, [])) > 0) != (length(coalesce(rule.match[0].dest_address_groups, [])) > 0) &&
        alltrue([for layer4 in rule.match[0].layer4_configs : layer4.ip_protocol == "tcp" && length(layer4.ports) == 1])
      ])
    )
    error_message = "The cluster's nodes may reach exactly the egress allowlist's named hosts, or one address group, each on one TCP port. Everything else must fall through to the deny."
  }

  assert {
    condition = (
      one(google_compute_network_firewall_policy_rule.cluster_egress_allowlist["smtp-relay"].match[0].dest_address_groups) == google_network_security_address_group.google_services.id &&
      alltrue([for range in google_network_security_address_group.google_services.items :
        can(cidrhost(range, 0)) && tonumber(split("/", range)[1]) >= 8
      ])
    )
    error_message = "SMTP may reach only Google's service ranges, each a valid IPv4 CIDR no wider than a /8."
  }

  assert {
    condition     = [for subnet in google_compute_router_nat.cluster.subnetwork : subnet.name] == [google_compute_subnetwork.cluster.id]
    error_message = "The cluster's Cloud NAT must serve the cluster's subnet alone."
  }

  assert {
    condition = alltrue([for networks in concat(
      [google_dns_policy.production.networks, google_dns_response_policy.allowlist.networks],
      [for zone in concat([google_dns_managed_zone.googleapis], values(google_dns_managed_zone.private_google_domain)) : one(zone.private_visibility_config).networks],
    ) : toset([for network in networks : network.network_url]) == toset([google_compute_network.cluster.id])])
    error_message = "The cluster's network must log its lookups, resolve through the private zones and resolve only the DNS allowlist."
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
    condition = alltrue([for name, repository in google_artifact_registry_repository.cluster_release :
      repository.project == google_project.workload.project_id &&
      one(repository.docker_config).immutable_tags &&
      google_artifact_registry_repository_iam_member.cluster_release[name].role == "roles/artifactregistry.reader" &&
      google_artifact_registry_repository_iam_member.cluster_release[name].member == google_service_account.runtime["cluster_nodes"].member
    ])
    error_message = "Each cluster-only release must sit in the workload project, which admission requires, with immutable tags the nodes only read."
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
    condition = (
      alltrue([for principal in var.database_operator_principals : google_project_iam_member.database_operator["${principal}:roles/container.clusterViewer"].role == "roles/container.clusterViewer"]) &&
      [for binding in values(google_project_iam_member.database_operator) : binding.role if startswith(binding.role, "roles/container.")] == [for principal in var.database_operator_principals : "roles/container.clusterViewer"]
    )
    error_message = "Operators may only connect to the cluster through IAM; the cluster root's RBAC decides what they read."
  }
}

run "copies_each_database_image_into_its_service_repository" {
  command = plan

  assert {
    condition = output.image_copies == [for service, ref in var.database_images : {
      source   = ref
      producer = "a-novel/service-${service}"
      workflow = "release.yaml"
      target   = "europe-west1-docker.pkg.dev/a-novel-production-prod/agora-${service}-private-production/service-${service}/database:${regex(":([^@]+)@", ref)[0]}"
    }]
    error_message = "Deploy must verify each database image against its service's release workflow and copy it into that service's production repository, which the cluster's databases pull from."
  }
}

run "keeps_api_calls_inside_production" {
  command = plan

  assert {
    condition = (
      google_access_context_manager_service_perimeter.production.use_explicit_dry_run_spec &&
      length(google_access_context_manager_service_perimeter.production.status) == 1 &&
      google_access_context_manager_service_perimeter.production.spec == google_access_context_manager_service_perimeter.production.status
    )
    error_message = "The perimeter must enforce its rules as its status, with a dry-run spec that repeats them."
  }

  assert {
    condition = (
      one(google_access_context_manager_service_perimeter.production.status[0].vpc_accessible_services).enable_restriction &&
      one(google_access_context_manager_service_perimeter.production.status[0].vpc_accessible_services).allowed_services == toset(["RESTRICTED-SERVICES"]) &&
      alltrue([for service in keys(google_project_service.workload) :
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

run "serves_each_platform_on_its_host" {
  command = plan

  assert {
    condition = (
      one(google_container_cluster.production.gateway_api_config).channel == "CHANNEL_STANDARD" &&
      alltrue([for policy in values(google_compute_ssl_policy.platform) : policy.profile == "MODERN" && policy.min_tls_version == "TLS_1_2"])
    )
    error_message = "The cluster must run the Gateway API, and each platform's edge must refuse TLS below 1.2."
  }

  assert {
    condition = (
      alltrue([for platform, edge in output.platform_edges :
        one(google_certificate_manager_certificate.platform[platform].managed).domains == tolist([edge.host]) &&
        length(one(google_certificate_manager_certificate.platform[platform].managed).dns_authorizations) == 1 &&
        google_certificate_manager_dns_authorization.platform[platform].domain == edge.host &&
        google_certificate_manager_certificate_map_entry.platform[platform].hostname == edge.host &&
        google_certificate_manager_certificate_map_entry.platform[platform].map == edge.certificate_map
      ]) &&
      output.platform_edges.studio.host == "studio.storyverse.fr" &&
      output.platform_edges.account.host == "account.storyverse.fr" &&
      contains(keys(google_project_iam_member.foundation), "roles/certificatemanager.editor")
    )
    error_message = "Each platform's certificate must cover only its host, authorized by DNS, and its map must serve it for that host, which the deploy identity may create."
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
