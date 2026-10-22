locals {
  # The only internet destinations, each open to the identities of the workloads that call it. The
  # service roots create these identities.
  egress_allowlist = {
    openai = {
      priority = 1000
      fqdn     = "api.openai.com"
      port     = "443"
      # GenAI's gRPC server and sweep.
      service_accounts = [
        "agora-genai-private@${var.workload_project_id}.iam.gserviceaccount.com",
        "agora-genai-sweep@${var.workload_project_id}.iam.gserviceaccount.com",
      ]
    }
    smtp-relay = {
      priority = 1010
      fqdn     = "smtp-relay.gmail.com"
      port     = "587"
      # Authentication's REST API, in the public-api project, and its maintenance job.
      service_accounts = [
        "agora-authentication-api@${var.public_api_project_id}.iam.gserviceaccount.com",
        "agora-authentication-maintain@${var.workload_project_id}.iam.gserviceaccount.com",
      ]
    }
  }
}

# All production internet egress leaves from this one address, so OpenAI's project and the Workspace
# SMTP relay can accept calls from it alone. A new address reaches both allowlists before it
# replaces this one.
resource "google_compute_address" "nat" {
  project = google_project.workload.project_id
  region  = var.region
  name    = "agora-production-nat"

  deletion_policy = "PREVENT"
  lifecycle {
    prevent_destroy = true
  }
}

# The workloads in the egress allowlist run their Direct VPC egress here, apart from the VMs, since
# Cloud NAT bills every instance it serves. At their caps and mid-rollout they hold 25 addresses,
# two per service instance and one per job task, which Cloud Run reserves 16 at a time. A /25 holds
# eight such blocks; Google's minimum is a /26.
resource "google_compute_subnetwork" "egress" {
  project = google_project.workload.project_id
  region  = var.region
  name    = "${local.network_name}-egress-${var.region}"

  ip_cidr_range            = var.egress_subnet_cidr
  network                  = google_compute_network.production.id
  private_ip_google_access = true
  stack_type               = "IPV4_ONLY"
}

resource "google_compute_router" "nat" {
  project = google_project.workload.project_id
  region  = var.region
  name    = "agora-production-nat"
  network = google_compute_network.production.id
}

# The firewall decides what reaches NAT: only the egress allowlist.
resource "google_compute_router_nat" "production" {
  project = google_project.workload.project_id
  region  = var.region
  router  = google_compute_router.nat.name
  name    = "agora-production-nat"

  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.nat.self_link]
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.egress.id
    source_ip_ranges_to_nat = ["PRIMARY_IP_RANGE"]
  }

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# Cloud NAT needs a default route. It is VPC-wide, but the database and repository VMs have neither
# NAT nor an external address, and the deny-all rule refuses their traffic first.
resource "google_compute_route" "internet" {
  project = google_project.workload.project_id
  name    = "default-internet"
  network = google_compute_network.production.id

  dest_range       = "0.0.0.0/0"
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

# Only a network firewall policy holds FQDN objects, which follow a host's changing addresses. It
# holds only the egress allowlist, so unmatched traffic falls through to the classic rules, where
# deny-all stops it. Direct VPC egress cannot log either verdict.
resource "google_compute_network_firewall_policy" "egress" {
  project     = google_project.workload.project_id
  name        = "agora-egress-allowlist"
  description = "The internet destinations each workload identity may reach, through Cloud NAT."
}

resource "google_compute_network_firewall_policy_association" "production" {
  project           = google_project.workload.project_id
  name              = local.network_name
  attachment_target = google_compute_network.production.id
  firewall_policy   = google_compute_network_firewall_policy.egress.id
}

resource "google_compute_network_firewall_policy_rule" "egress_allowlist" {
  for_each = local.egress_allowlist

  project         = google_project.workload.project_id
  firewall_policy = google_compute_network_firewall_policy.egress.name
  rule_name       = each.key
  priority        = each.value.priority
  direction       = "EGRESS"
  action          = "allow"

  target_service_accounts = each.value.service_accounts

  match {
    dest_fqdns = [each.value.fqdn]

    layer4_configs {
      ip_protocol = "tcp"
      ports       = [each.value.port]
    }
  }
}
