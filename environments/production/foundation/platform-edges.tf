# Each platform's public edge (a-novel/infra#1201): the address its Gateway in the cluster root listens
# on, the TLS it accepts, and the certificate Google issues for its host. The domain's DNS authorizes
# the certificate before any traffic moves, so going live only points the host at the address.
locals {
  platform_hosts = {
    account = "account.storyverse.fr"
    studio  = "studio.storyverse.fr"
  }
}

# The domain's DNS points each host here, so the address outlives any Gateway.
resource "google_compute_global_address" "platform" {
  for_each = local.platform_hosts

  project = google_project.workload.project_id
  name    = each.key

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
}

moved {
  from = google_compute_global_address.studio
  to   = google_compute_global_address.platform["studio"]
}

resource "google_compute_ssl_policy" "platform" {
  for_each = local.platform_hosts

  project         = google_project.workload.project_id
  name            = each.key
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
}

moved {
  from = google_compute_ssl_policy.studio
  to   = google_compute_ssl_policy.platform["studio"]
}

# The deploy identity creates Certificate Manager's resources with the role foundation grants it.
resource "google_certificate_manager_dns_authorization" "platform" {
  for_each = local.platform_hosts

  project = google_project.workload.project_id
  name    = each.key
  domain  = each.value

  depends_on = [google_project_service.workload["certificatemanager.googleapis.com"], google_project_iam_member.foundation]
}

moved {
  from = google_certificate_manager_dns_authorization.studio
  to   = google_certificate_manager_dns_authorization.platform["studio"]
}

resource "google_certificate_manager_certificate" "platform" {
  for_each = local.platform_hosts

  project = google_project.workload.project_id
  name    = each.key

  managed {
    domains            = [each.value]
    dns_authorizations = [google_certificate_manager_dns_authorization.platform[each.key].id]
  }
}

moved {
  from = google_certificate_manager_certificate.studio
  to   = google_certificate_manager_certificate.platform["studio"]
}

resource "google_certificate_manager_certificate_map" "platform" {
  for_each = local.platform_hosts

  project = google_project.workload.project_id
  name    = each.key

  depends_on = [google_project_service.workload["certificatemanager.googleapis.com"], google_project_iam_member.foundation]
}

moved {
  from = google_certificate_manager_certificate_map.studio
  to   = google_certificate_manager_certificate_map.platform["studio"]
}

resource "google_certificate_manager_certificate_map_entry" "platform" {
  for_each = local.platform_hosts

  project      = google_project.workload.project_id
  name         = each.key
  map          = google_certificate_manager_certificate_map.platform[each.key].name
  hostname     = each.value
  certificates = [google_certificate_manager_certificate.platform[each.key].id]
}

moved {
  from = google_certificate_manager_certificate_map_entry.studio
  to   = google_certificate_manager_certificate_map_entry.platform["studio"]
}

locals {
  platform_edges = { for platform, host in local.platform_hosts : platform => {
    host            = host
    address_name    = google_compute_global_address.platform[platform].name
    ssl_policy      = google_compute_ssl_policy.platform[platform].name
    certificate_map = google_certificate_manager_certificate_map.platform[platform].name
    dns_records = {
      authorization = one(google_certificate_manager_dns_authorization.platform[platform].dns_resource_record)
      address       = { name = "${host}.", type = "A", data = google_compute_global_address.platform[platform].address }
    }
  } }
}

output "platform_edges" {
  description = "Each platform's public edge, which its Gateway in the cluster root names, and the DNS records its host needs: the certificate's authorization first, then the address."
  value       = local.platform_edges
}
