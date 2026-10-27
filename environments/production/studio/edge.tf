# A global external Application Load Balancer serves the domain with a Google-managed certificate.
# The certificate provisions once the domain's DNS A record names the address, which DNS outside
# this repository holds.
resource "google_compute_global_address" "web" {
  project = local.project_id
  name    = "agora-studio-web"
}

resource "google_compute_region_network_endpoint_group" "web" {
  project               = local.project_id
  name                  = "agora-studio-web"
  region                = local.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = google_cloud_run_v2_service.web.name
  }
}

resource "google_compute_backend_service" "web" {
  project               = local.project_id
  name                  = "agora-studio-web"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTPS"

  backend {
    group = google_compute_region_network_endpoint_group.web.id
  }
}

resource "google_compute_url_map" "web" {
  project         = local.project_id
  name            = "agora-studio-web"
  default_service = google_compute_backend_service.web.id
}

resource "google_compute_managed_ssl_certificate" "web" {
  project = local.project_id
  name    = "agora-studio-web"

  managed {
    domains = [var.domain]
  }
}

# The default policy still accepts TLS 1.0. Every browser Studio supports speaks TLS 1.2.
resource "google_compute_ssl_policy" "web" {
  project         = local.project_id
  name            = "agora-studio-web"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_target_https_proxy" "web" {
  project          = local.project_id
  name             = "agora-studio-web"
  url_map          = google_compute_url_map.web.id
  ssl_certificates = [google_compute_managed_ssl_certificate.web.id]
  ssl_policy       = google_compute_ssl_policy.web.id
}

resource "google_compute_global_forwarding_rule" "https" {
  project               = local.project_id
  name                  = "agora-studio-web-https"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.web.id
  port_range            = "443"
  target                = google_compute_target_https_proxy.web.id
}

# Plain HTTP on the same address only redirects to HTTPS.
resource "google_compute_url_map" "redirect" {
  project = local.project_id
  name    = "agora-studio-web-redirect"

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  project = local.project_id
  name    = "agora-studio-web-redirect"
  url_map = google_compute_url_map.redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  project               = local.project_id
  name                  = "agora-studio-web-http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  ip_address            = google_compute_global_address.web.id
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
}
