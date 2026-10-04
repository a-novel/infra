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
      var.foundation.schema_version == local.coordinates_version &&
      var.foundation.bucket == var.state_bucket &&
      var.foundation.object == "foundation/coordinates/${local.coordinate_scope}/${var.foundation.sha256}.json"
    )
    error_message = "Pin the expected coordinate schema in this service's exact foundation folder and management bucket."
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
    ] : contract.schema_version == local.coordinates_version]), false)
    error_message = "Supply the expected schema for both runtime and database contracts; an absent database is not deployable."
  }
  validation {
    condition = try(
      jsondecode(var.foundation_json).runtime.project_id == var.project_id &&
      jsondecode(var.foundation_json).runtime.service == var.service &&
      jsondecode(var.foundation_json).runtime.region == var.region &&
      jsondecode(var.foundation_json).runtime.service_account == "agora-${var.service}${var.zone == null ? "" : "-${local.zone_suffix}"}@${var.project_id}.iam.gserviceaccount.com",
    false)
    error_message = "The runtime must match the independently approved project, service, region and application identity."
  }
  validation {
    condition = var.zone == null ? true : try(
      jsondecode(var.foundation_json).scope == local.coordinate_scope &&
      jsondecode(var.foundation_json).runtime.zone == var.zone &&
      jsondecode(var.foundation_json).runtime.repositories["agora-production"] == local.production_repository &&
      jsondecode(var.foundation_json).database_source.schema_version == 2 &&
      jsondecode(var.foundation_json).database_source.bucket == var.state_bucket &&
      jsondecode(var.foundation_json).database_source.object == "foundation/database-coordinates/production/${local.database_project}/${var.service}/${jsondecode(var.foundation_json).database_source.sha256}.json" &&
      can(regex("^[1-9][0-9]*$", jsondecode(var.foundation_json).database_source.generation)) &&
      can(regex("^[a-f0-9]{64}$", jsondecode(var.foundation_json).database_source.sha256)),
    false)
    error_message = "Shared releases require their exact service/zone, registry and approved private database source reference."
  }
  validation {
    condition = try(
      jsondecode(var.foundation_json).database.project_id == local.database_project &&
      jsondecode(var.foundation_json).database.service == var.service &&
      can(regex("^${var.region}-[a-z]$", jsondecode(var.foundation_json).database.zone)) &&
      jsondecode(var.foundation_json).database.port == (var.service == "json-keys" ? 5432 : 5433),
    false)
    error_message = "The database must belong to the selected private project, service and region, with its expected PostgreSQL port."
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
  coordinates           = try(jsondecode(var.foundation_json), null)
  coordinates_version   = var.zone == null ? 1 : 2
  coordinate_scope      = var.zone == null ? var.project_id : "workloads/production/${var.zone}/${var.project_id}/${var.service}"
  zone_suffix           = var.zone == "public-api" ? "api" : "private"
  database_project      = var.zone == "public-api" ? coalesce(var.private_project_id, "unconfigured") : var.project_id
  production_repository = "${var.region}-docker.pkg.dev/${var.project_id}/${var.zone == null ? "agora-production" : "agora-${var.service}-${local.zone_suffix}-production"}"
}
