# Studio's public edge (a-novel/infra#1201): the address the cluster root's Gateway listens on, the
# TLS it accepts, and the certificate Google issues for Studio's host. The domain's DNS authorizes
# the certificate before any traffic moves, so the cutover only points the host at the address.
locals {
  studio_host = "studio.agorastoryverse.com"
}

# The domain's DNS points the host here, so the address outlives any Gateway.
resource "google_compute_global_address" "studio" {
  project = google_project.workload.project_id
  name    = "studio"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
}

resource "google_compute_ssl_policy" "studio" {
  project         = google_project.workload.project_id
  name            = "studio"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"

  depends_on = [google_project_service.workload["compute.googleapis.com"]]
}

resource "google_certificate_manager_dns_authorization" "studio" {
  project = google_project.workload.project_id
  name    = "studio"
  domain  = local.studio_host

  depends_on = [google_project_service.workload["certificatemanager.googleapis.com"]]
}

resource "google_certificate_manager_certificate" "studio" {
  project = google_project.workload.project_id
  name    = "studio"

  managed {
    domains            = [local.studio_host]
    dns_authorizations = [google_certificate_manager_dns_authorization.studio.id]
  }
}

resource "google_certificate_manager_certificate_map" "studio" {
  project = google_project.workload.project_id
  name    = "studio"

  depends_on = [google_project_service.workload["certificatemanager.googleapis.com"]]
}

resource "google_certificate_manager_certificate_map_entry" "studio" {
  project      = google_project.workload.project_id
  name         = "studio"
  map          = google_certificate_manager_certificate_map.studio.name
  hostname     = local.studio_host
  certificates = [google_certificate_manager_certificate.studio.id]
}

output "studio_edge" {
  description = "Studio's public edge, which the cluster root's Gateway names, and the DNS records its host needs: the certificate's authorization first, the address at the cutover."
  value = {
    host            = local.studio_host
    address_name    = google_compute_global_address.studio.name
    ssl_policy      = google_compute_ssl_policy.studio.name
    certificate_map = google_certificate_manager_certificate_map.studio.name
    dns_records = {
      authorization = one(google_certificate_manager_dns_authorization.studio.dns_resource_record)
      address       = { name = "${local.studio_host}.", type = "A", data = google_compute_global_address.studio.address }
    }
  }
}
