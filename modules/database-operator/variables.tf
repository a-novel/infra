variable "images" {
  description = "Each image the charts run, as they render it: its repository in the caller's registry, and tag@digest as its tag."
  type = map(object({
    repository = string
    tag        = string
  }))

  validation {
    condition     = length(setsubtract(["cert_manager_controller", "cert_manager_webhook", "cert_manager_cainjector", "cloudnative_pg", "plugin_barman_cloud", "plugin_barman_cloud_sidecar"], keys(var.images))) == 0
    error_message = "Pass every image the three charts run."
  }
}

variable "namespaces" {
  description = "The namespaces cert-manager and CloudNativePG install into. The plugin joins CloudNativePG's."
  type = object({
    cert_manager   = string
    cloudnative_pg = string
  })
}
