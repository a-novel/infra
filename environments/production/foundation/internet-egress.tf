locals {
  # The only internet destinations. On agora-production each opens to the identities of the
  # workloads that call it, which the service roots create; a destination naming none serves the
  # cluster alone. The cluster's nodes reach them all, and each workload's network policy narrows
  # them. The DNS allowlist resolves each host, and the firewall matches it by name unless the
  # destination names address groups.
  egress_allowlist = {
    openai = {
      priority = 1000
      # Cloudflare gives every client the same two anycast addresses, so the firewall resolves
      # the ones its clients do.
      hosts          = ["api.openai.com"]
      address_groups = []
      port           = "443"
      # GenAI's gRPC server and sweep.
      service_accounts = [
        "agora-genai-private@${var.workload_project_id}.iam.gserviceaccount.com",
        "agora-genai-sweep@${var.workload_project_id}.iam.gserviceaccount.com",
      ]
    }
    smtp-relay = {
      priority = 1010
      # smtp-relay.gmail.com answers each client location with another frontend, which the
      # firewall's own lookup rarely matches, so the rule admits all of Google's service ranges.
      hosts          = ["smtp-relay.gmail.com"]
      address_groups = [google_network_security_address_group.google_services.id]
      port           = "587"
      # Authentication's REST API, in the public-api project, and its maintenance job.
      service_accounts = [
        "agora-authentication-api@${var.public_api_project_id}.iam.gserviceaccount.com",
        "agora-authentication-maintain@${var.workload_project_id}.iam.gserviceaccount.com",
      ]
    }
    sentry = {
      priority = 1020
      # Sentry's ingest sits behind one Google Cloud anycast address that every client resolves
      # alike, so the firewall resolves the one its clients do.
      hosts          = [var.sentry_ingest_host]
      address_groups = []
      port           = "443"
      # The servers, GenAI's sweep, and the jobs that report their faults: Authentication's
      # maintenance and refresh token purge, which share one identity, and JSON Keys' key rotation.
      service_accounts = [
        "agora-authentication-api@${var.public_api_project_id}.iam.gserviceaccount.com",
        "agora-authentication-maintain@${var.workload_project_id}.iam.gserviceaccount.com",
        "agora-json-keys-private@${var.workload_project_id}.iam.gserviceaccount.com",
        "agora-json-keys-rotatekeys@${var.workload_project_id}.iam.gserviceaccount.com",
        "agora-genai-private@${var.workload_project_id}.iam.gserviceaccount.com",
        "agora-genai-sweep@${var.workload_project_id}.iam.gserviceaccount.com",
      ]
    }
    github-raw = {
      priority = 1030
      # Studio's planned downtime document. GitHub serves it from four anycast addresses that every
      # client resolves alike.
      hosts          = ["raw.githubusercontent.com"]
      address_groups = []
      port           = "443"
      # The cluster's Studio alone: Cloud Run's leaves through its own project.
      service_accounts = []
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
# Cloud NAT bills every instance it serves. At their caps and mid-rollout they hold 35 addresses,
# two per service instance and one per job task, which Cloud Run reserves 16 at a time. Counting a
# block per workload, they fill a /25, so this is a /24; Google's minimum is a /26. A subnet's range
# grows in place but never shrinks.
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

# Every range Google announces minus those its Cloud customers rent, so no customer VM can listen
# behind it. refresh-google-ranges.yaml rewrites the file from Google's lists. The
# capacity is fixed at creation and counts against the policy's attribute quota in full.
locals {
  google_services = {
    ranges   = jsondecode(file("${path.module}/google-service-ranges.json"))
    capacity = 500
  }
}

resource "google_network_security_address_group" "google_services" {
  parent      = "projects/${google_project.workload.project_id}"
  location    = "global"
  name        = "google-services"
  description = "Google's own service ranges, outside every range Cloud customers can rent."
  type        = "IPV4"
  capacity    = local.google_services.capacity
  items       = local.google_services.ranges

  lifecycle {
    precondition {
      condition     = length(local.google_services.ranges) > 0 && length(local.google_services.ranges) <= local.google_services.capacity
      error_message = "The Google service ranges must be non-empty and fit the group's fixed capacity."
    }
  }

  depends_on = [google_project_service.workload["networksecurity.googleapis.com"]]
}

resource "google_compute_network_firewall_policy_rule" "egress_allowlist" {
  for_each = { for name, destination in local.egress_allowlist : name => destination if length(destination.service_accounts) > 0 }

  project         = google_project.workload.project_id
  firewall_policy = google_compute_network_firewall_policy.egress.name
  rule_name       = each.key
  priority        = each.value.priority
  direction       = "EGRESS"
  action          = "allow"

  target_service_accounts = each.value.service_accounts

  match {
    dest_fqdns          = length(each.value.address_groups) > 0 ? [] : each.value.hosts
    dest_address_groups = each.value.address_groups

    layer4_configs {
      ip_protocol = "tcp"
      ports       = [each.value.port]
    }
  }
}
