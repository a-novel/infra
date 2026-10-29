# The cluster's network, which replaces agora-production at the cutover (a-novel/.github#522). Only
# the cluster's nodes run here, so its firewall applies network-wide, and the cluster's network
# policies narrow it per workload. Retirement deletes agora-production and the peering.
resource "google_compute_network" "cluster" {
  project = google_project.workload.project_id
  name    = "a-novel-production"

  auto_create_subnetworks         = false
  delete_default_routes_on_create = true
  mtu                             = 1460
  routing_mode                    = "REGIONAL"
  # The egress allowlist's policy runs first: the classic deny-all would otherwise win.
  network_firewall_policy_enforcement_order = "BEFORE_CLASSIC_FIREWALL"

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
  lifecycle {
    prevent_destroy = true
  }
}

# The nodes take the primary range, and the control plane's private endpoint an address in it.
resource "google_compute_subnetwork" "cluster" {
  project = google_project.workload.project_id
  region  = var.cluster_region
  name    = "a-novel-production-${var.cluster_region}"

  ip_cidr_range            = var.cluster_ranges.nodes
  network                  = google_compute_network.cluster.id
  private_ip_google_access = true
  stack_type               = "IPV4_ONLY"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.cluster_ranges.pods
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.cluster_ranges.services
  }
}

# Like agora-production, the network starts without Google's default routes.
resource "google_compute_route" "cluster_restricted_google_apis" {
  for_each = local.restricted_google_api_ranges

  project = google_project.workload.project_id
  name    = "a-novel-restricted-google-${replace(replace(each.value, ".", "-"), "/", "-")}"
  network = google_compute_network.cluster.id

  dest_range       = each.value
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

resource "google_compute_route" "cluster_internet" {
  project = google_project.workload.project_id
  name    = "a-novel-default-internet"
  network = google_compute_network.cluster.id

  dest_range       = "0.0.0.0/0"
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

# The cluster's internet egress leaves from this address. OpenAI's project and the Workspace SMTP
# relay list it beside agora-production-nat before any workload moves.
resource "google_compute_address" "cluster_nat" {
  project = google_project.workload.project_id
  region  = var.cluster_region
  name    = "a-novel-production-nat"

  # Unlocked while the cluster moves to Paris, and locked again once it runs.
  deletion_policy = "DELETE"
}

resource "google_compute_router" "cluster_nat" {
  project = google_project.workload.project_id
  region  = var.cluster_region
  name    = "a-novel-production-nat"
  network = google_compute_network.cluster.id
}

resource "google_compute_router_nat" "cluster" {
  project = google_project.workload.project_id
  region  = var.cluster_region
  router  = google_compute_router.cluster_nat.name
  name    = "a-novel-production-nat"

  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.cluster_nat.self_link]
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.cluster.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  # Every pod on a node shares the node's NAT ports, so a busy node takes more of them.
  enable_dynamic_port_allocation      = true
  enable_endpoint_independent_mapping = false

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "cluster_allow_restricted_google_apis" {
  depends_on = [google_project_iam_member.foundation_firewall]

  project = google_project.workload.project_id
  name    = "a-novel-allow-restricted-google-apis"
  network = google_compute_network.cluster.name

  direction          = "EGRESS"
  priority           = 800
  destination_ranges = sort(tolist(local.restricted_google_api_ranges))

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
}

# Nodes and pods talk to each other on any port, and the nodes reach the control plane's endpoint
# inside the node range.
resource "google_compute_firewall" "cluster_allow_internal_egress" {
  depends_on = [google_project_iam_member.foundation_firewall]

  project = google_project.workload.project_id
  name    = "a-novel-allow-cluster-egress"
  network = google_compute_network.cluster.name

  direction          = "EGRESS"
  priority           = 800
  destination_ranges = [var.cluster_ranges.nodes, var.cluster_ranges.pods]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "cluster_deny_other_egress" {
  depends_on = [google_project_iam_member.foundation_firewall]

  project = google_project.workload.project_id
  name    = "a-novel-deny-other-vpc-egress"
  network = google_compute_network.cluster.name

  direction          = "EGRESS"
  priority           = 1200
  destination_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }
}

# Firewall rules see the node's identity, never a pod's, so every node may reach every host of the
# egress allowlist, and each workload's FQDN network policy admits only its own.
resource "google_compute_network_firewall_policy" "cluster_egress" {
  project     = google_project.workload.project_id
  name        = "a-novel-egress-allowlist"
  description = "The internet destinations the cluster's nodes may reach, through Cloud NAT."
}

resource "google_compute_network_firewall_policy_association" "cluster" {
  project           = google_project.workload.project_id
  name              = "a-novel-production"
  attachment_target = google_compute_network.cluster.id
  firewall_policy   = google_compute_network_firewall_policy.cluster_egress.id
}

resource "google_compute_network_firewall_policy_rule" "cluster_egress_allowlist" {
  for_each = local.egress_allowlist

  project         = google_project.workload.project_id
  firewall_policy = google_compute_network_firewall_policy.cluster_egress.name
  rule_name       = each.key
  priority        = each.value.priority
  direction       = "EGRESS"
  action          = "allow"

  match {
    dest_fqdns          = length(each.value.address_groups) > 0 ? [] : each.value.hosts
    dest_address_groups = each.value.address_groups

    layer4_configs {
      ip_protocol = "tcp"
      ports       = [each.value.port]
    }
  }
}

# The cutover imports each database from its host across this peering. Neither network's firewall
# admits the other yet: the import opens the database hosts to the pod range.
resource "google_compute_network_peering" "cluster_to_agora" {
  name         = "a-novel-database-imports"
  network      = google_compute_network.cluster.id
  peer_network = google_compute_network.production.id
}

resource "google_compute_network_peering" "agora_to_cluster" {
  name         = "a-novel-database-imports"
  network      = google_compute_network.production.id
  peer_network = google_compute_network.cluster.id

  # Google refuses a peering operation on a network while another one runs.
  depends_on = [google_compute_network_peering.cluster_to_agora]
}
