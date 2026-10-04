variable "authentication" {
  description = "Public Authentication API's approved non-secret settings; private migration scope never consumes SMTP or peer API configuration."
  type = object({
    json_keys_host     = string
    platform_auth_url  = string
    smtp_address       = string
    smtp_username      = string
    smtp_sender_domain = string
    smtp_sender_email  = string
    smtp_sender_name   = string
    waitlist_url       = optional(string)
  })
  default = null

  validation {
    condition     = (var.authentication != null) == (var.zone == "public-api" && var.service == "authentication" && var.api != null)
    error_message = "Only a configured public Authentication API requires Authentication settings."
  }
  validation {
    condition = var.authentication == null ? true : try(alltrue([
      for key, pattern in {
        json_keys_host     = "^agora-json-keys-grpc-[a-z0-9-]+\\.(a|[a-z]+-[a-z]+[1-9][0-9]*)\\.run\\.app$"
        platform_auth_url  = "^(https://[^\\s\"\\\\]+)?$"
        smtp_address       = "^[a-zA-Z0-9.-]+:[1-9][0-9]{0,4}$"
        smtp_username      = "^[^\\r\\n\\x00]{1,512}$"
        smtp_sender_domain = "^[a-zA-Z0-9.-]+$"
        smtp_sender_email  = "^[^\\s@]+@[^\\s@]+$"
        smtp_sender_name   = "^[^\\r\\n\\x00]{1,512}$"
      } : length(var.authentication[key]) <= 512 && can(regex(pattern, var.authentication[key]))
    ]), false)
    error_message = "Use bounded non-secret SMTP settings, the selected JSON Keys hostname and an HTTPS or empty platform URL."
  }
  validation {
    condition = try(var.authentication.waitlist_url, null) == null ? true : try(
      length(var.authentication.waitlist_url) <= 512 && can(regex("^https://[^\\s\"\\\\]+$", var.authentication.waitlist_url)), false
    )
    error_message = "Optional waitlist access requires a bounded HTTPS endpoint and its exact numeric secret version."
  }
}

locals {
  authentication_environment = merge({
    SERVICE_JSON_KEYS_HOST = try(var.authentication.json_keys_host, "")
    SERVICE_JSON_KEYS_PORT = "443"
    PLATFORM_AUTH_URL      = try(var.authentication.platform_auth_url, "")
    REST_TIMEOUT_SHUTDOWN  = "9s"
    SMTP_ADDR              = try(var.authentication.smtp_address, "")
    SMTP_USERNAME          = try(var.authentication.smtp_username, "")
    SMTP_SENDER_DOMAIN     = try(var.authentication.smtp_sender_domain, "")
    SMTP_SENDER_EMAIL      = try(var.authentication.smtp_sender_email, "")
    SMTP_SENDER_NAME       = try(var.authentication.smtp_sender_name, "")
    SMTP_MAX_CONCURRENT    = "8"
    SMTP_TIMEOUT           = "5s"
    }, try(var.authentication.waitlist_url, null) == null ? {} : {
    WAITLIST_URL = var.authentication.waitlist_url
  })
}
