locals {
  # A private zone or Compute Engine's internal DNS answers every name under these domains inside
  # Google, metadata.google.internal included, so no lookup under them reaches the internet.
  dns_google_domains = concat(
    [google_dns_managed_zone.googleapis.dns_name, "internal."],
    [for zone in google_dns_managed_zone.private_google_domain : zone.dns_name],
  )
  dns_public_hosts = [for host in flatten([for destination in values(local.egress_allowlist) : destination.hosts]) : "${host}."]

  dns_allowed = setunion(
    local.dns_public_hosts,
    local.dns_google_domains,
    [for domain in local.dns_google_domains : "*.${domain}"],
  )

  # Cloud DNS stops applying a wildcard below any level another rule names, so every level above
  # an allowed name is denied on its own, up to the root. An allowed host's subdomains are denied
  # too.
  dns_denied = setsubtract(flatten([
    for labels in [for name in setunion(local.dns_public_hosts, local.dns_google_domains) : split(".", name)] : [
      for level in range(length(labels)) : join(".", concat(["*"], slice(labels, level, length(labels))))
    ]
  ]), local.dns_allowed)

  # Cloud DNS answers a refused lookup with this CNAME alone, so the client gets no address. Internal
  # DNS holds no such name, so a client that follows the CNAME finds none either.
  dns_refusal = "blocked.internal."
}

# A lookup of a name its owner's name server logs can carry data out, so the network resolves only
# the allowlist. The egress firewall resolves its hosts through this policy too.
resource "google_dns_response_policy" "allowlist" {
  project              = google_project.workload.project_id
  response_policy_name = "agora-dns-allowlist"
  description          = "Resolve only the private zones, internal names and the egress allowlist's hosts."

  networks {
    network_url = google_compute_network.production.id
  }

  depends_on = [google_project_service.workload["dns.googleapis.com"]]
}

# Only the beta provider sets a rule's behavior.
resource "google_dns_response_policy_rule" "allow" {
  provider = google-beta
  for_each = local.dns_allowed

  project         = google_project.workload.project_id
  response_policy = google_dns_response_policy.allowlist.response_policy_name
  rule_name       = "allow-${replace(replace(trimsuffix(each.key, "."), "*", "any"), ".", "-")}"
  dns_name        = each.key
  behavior        = "bypassResponsePolicy"
}

# Every allowed name resolves before the first refusal applies, so creating the policy never
# refuses one.
resource "google_dns_response_policy_rule" "deny" {
  for_each = local.dns_denied

  project         = google_project.workload.project_id
  response_policy = google_dns_response_policy.allowlist.response_policy_name
  rule_name       = "deny-${replace(replace(trimsuffix(each.key, "."), "*", "any"), ".", "-")}"
  dns_name        = each.key

  # A CNAME answers every record type.
  local_data {
    local_datas {
      name    = each.key
      type    = "CNAME"
      ttl     = 300
      rrdatas = [local.dns_refusal]
    }
  }

  depends_on = [google_dns_response_policy_rule.allow]
}
