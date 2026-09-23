variable "foundation" {
  description = "Exact coordinate reference approved after a successful protected foundation apply and convergence."
  type = object({
    schema_version = number
    bucket         = string
    object         = string
    generation     = string
    sha256         = string
  })
  nullable = false

  validation {
    condition = (
      var.foundation.schema_version == 1 &&
      var.foundation.bucket == var.state_bucket &&
      var.foundation.object == "foundation/coordinates/${var.project_id}/${var.foundation.sha256}.json"
    )
    error_message = "Pin a version-1 coordinate reference in this service's foundation folder and management bucket."
  }
  validation {
    condition = (
      can(regex("^[1-9][0-9]*$", var.foundation.generation)) &&
      can(regex("^[a-f0-9]{64}$", var.foundation.sha256))
    )
    error_message = "Pin a positive generation and a lowercase SHA-256 digest; latest is not accepted."
  }
}

variable "foundation_json" {
  description = "Unmodified JSON text fetched from the approved foundation generation; contains coordinates, never state or secret payloads."
  type        = string
  nullable    = false

  validation {
    condition     = sha256(var.foundation_json) == var.foundation.sha256
    error_message = "Foundation bytes do not match the approved checksum; fetch the exact generation without rewriting its content."
  }
  validation {
    condition = try(alltrue([for contract in [
      jsondecode(var.foundation_json), jsondecode(var.foundation_json).runtime, jsondecode(var.foundation_json).database,
    ] : contract.schema_version == 1]), false)
    error_message = "Supply version-1 JSON coordinates with both runtime and database contracts; an absent database is not deployable."
  }
  validation {
    condition = try(
      jsondecode(var.foundation_json).runtime.project_id == var.project_id &&
      jsondecode(var.foundation_json).runtime.service == var.service &&
      jsondecode(var.foundation_json).runtime.region == var.region &&
      jsondecode(var.foundation_json).runtime.service_account == "agora-${var.service}@${var.project_id}.iam.gserviceaccount.com",
    false)
    error_message = "The runtime must match the independently approved project, service, region and application identity."
  }
  validation {
    condition = try(
      jsondecode(var.foundation_json).database.project_id == var.project_id &&
      jsondecode(var.foundation_json).database.service == var.service &&
      can(regex("^${var.region}-[a-z]$", jsondecode(var.foundation_json).database.zone)) &&
      jsondecode(var.foundation_json).database.port == (var.service == "json-keys" ? 5432 : 5433),
    false)
    error_message = "The database must belong to this service project and region, with its expected PostgreSQL port."
  }
  validation {
    condition = try(
      can(cidrnetmask("${jsondecode(var.foundation_json).database.private_ip}/32")) &&
      can(regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)", jsondecode(var.foundation_json).database.private_ip)),
    false)
    error_message = "The foundation database endpoint must be a private IPv4 address."
  }
}

locals {
  coordinates = try(jsondecode(var.foundation_json), null)
}
