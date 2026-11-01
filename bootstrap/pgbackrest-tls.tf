variable "native_backups" {
  description = "Services whose database hosts had native backups. With tls_credentials, their TLS secret containers retire after the hosts (a-novel/infra#1208)."
  type = map(object({
    workload_project_id = string
    zone                = string
    tls_credentials     = optional(bool, false)
    noncurrent_cleanup  = optional(bool, false)
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([for service, config in var.native_backups :
      contains(["json-keys", "authentication", "genai"], service) &&
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", config.workload_project_id)) &&
      config.workload_project_id != var.management_project_id
    ])
    error_message = "Select a supported service and its registered database project, distinct from management."
  }

  validation {
    condition     = alltrue([for config in var.native_backups : config.zone == "private"])
    error_message = "Native backup custody belongs only to the private zone."
  }
}

locals {
  pgbackrest_tls_endpoints = {
    ca = {
      contract = "PGBACKREST_CA_PEM"
      purpose  = "native backup public TLS trust bundle"
    }
    database = {
      contract = "PGBACKREST_IDENTITY_PEM"
      purpose  = "database TLS client certificate and private key"
    }
    repository = {
      contract = "PGBACKREST_IDENTITY_PEM"
      purpose  = "repository TLS server certificate and private key"
    }
  }

  pgbackrest_tls = merge([for service, config in var.native_backups : {
    for endpoint, credential in local.pgbackrest_tls_endpoints : "production-${service}-pgbackrest-${endpoint}" => {
      contract = credential.contract
      purpose  = "${service} ${credential.purpose}"
    }
  } if config.tls_credentials]...)
}
