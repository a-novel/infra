variable "database_handoff" {
  description = "Approved existing-database reference and original downloaded bytes; null keeps shared prerequisites database-free."
  type = object({
    private_project_id = string
    reference = object({
      schema_version = number
      bucket         = string
      object         = string
      generation     = string
      sha256         = string
    })
    document_json = string
  })
  default = null

  validation {
    condition = var.database_handoff == null ? true : (
      var.zone != null && var.database == null &&
      can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.database_handoff.private_project_id)) &&
      var.database_handoff.private_project_id != var.management_project_id &&
      (var.zone == "private" ? var.database_handoff.private_project_id == var.project_id : var.database_handoff.private_project_id != var.project_id)
    )
    error_message = "Existing-database handoff belongs only to shared zones; independently select the private project and retain its host owner."
  }
  validation {
    condition = var.database_handoff == null ? true : (
      var.database_handoff.reference.schema_version == 2 &&
      var.database_handoff.reference.bucket == var.state_bucket &&
      var.database_handoff.reference.object == "foundation/database-coordinates/production/${var.database_handoff.private_project_id}/${var.service}/${var.database_handoff.reference.sha256}.json" &&
      can(regex("^[1-9][0-9]*$", var.database_handoff.reference.generation)) &&
      can(regex("^[a-f0-9]{64}$", var.database_handoff.reference.sha256)) &&
      sha256(var.database_handoff.document_json) == var.database_handoff.reference.sha256
    )
    error_message = "Pin the exact schema-2 service database object, positive generation and checksum of its original bytes in the management bucket."
  }
  validation {
    condition = var.database_handoff == null ? true : try(
      toset(keys(jsondecode(var.database_handoff.document_json))) == toset(["schema_version", "service", "project_id", "zone", "private_ip", "port"]) &&
      jsondecode(var.database_handoff.document_json).schema_version == 2 &&
      jsondecode(var.database_handoff.document_json).service == var.service &&
      jsondecode(var.database_handoff.document_json).project_id == var.database_handoff.private_project_id &&
      can(regex("^${var.region}-[a-z]$", jsondecode(var.database_handoff.document_json).zone)) &&
      jsondecode(var.database_handoff.document_json).port == (var.service == "json-keys" ? 5432 : 5433) &&
      can(cidrnetmask("${jsondecode(var.database_handoff.document_json).private_ip}/32")) &&
      can(regex("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)", jsondecode(var.database_handoff.document_json).private_ip)),
    false)
    error_message = "Supply only this service's minimal schema-2 database contract with its private project, regional zone, PostgreSQL port and private IPv4 endpoint."
  }
}
