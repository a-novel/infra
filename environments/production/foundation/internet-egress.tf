locals {
  # The only internet destinations. The cluster's nodes reach them all, and each workload's network
  # policy narrows them. The DNS allowlist resolves each host, and the firewall matches it by name
  # unless the destination names address groups.
  egress_allowlist = {
    openai = {
      priority = 1000
      # Cloudflare gives every client the same two anycast addresses, so the firewall resolves
      # the ones its clients do.
      hosts          = ["api.openai.com"]
      address_groups = []
      port           = "443"
    }
    smtp-relay = {
      priority = 1010
      # smtp-relay.gmail.com answers each client location with another frontend, which the
      # firewall's own lookup rarely matches, so the rule admits all of Google's service ranges.
      hosts          = ["smtp-relay.gmail.com"]
      address_groups = [google_network_security_address_group.google_services.id]
      port           = "587"
    }
    github-raw = {
      priority = 1030
      # Studio's planned downtime document. GitHub serves it from four anycast addresses that every
      # client resolves alike.
      hosts          = ["raw.githubusercontent.com"]
      address_groups = []
      port           = "443"
    }
    grafana-otlp = {
      priority = 1040
      # The Grafana Cloud stack's OTLP gateway, which receives every signal. It answers every client
      # with the same address.
      hosts          = ["otlp-gateway-prod-eu-west-2.grafana.net"]
      address_groups = []
      port           = "443"
    }
  }
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
