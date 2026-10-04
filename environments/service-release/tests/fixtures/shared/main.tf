module "handoff" {
  source = "../../../../service-foundation/tests/fixtures/handoff"
}

variable "zone" {
  type    = string
  default = "private"
}

locals {
  project = var.zone == "public-api" ? "agora-public-api-test" : "agora-private-test"
  suffix  = var.zone == "public-api" ? "api" : "private"
  role    = var.zone == "public-api" ? "rest" : "grpc"
  documents = { for service in ["json-keys", "authentication"] : service => {
    schema_version = 2
    scope          = "workloads/production/${var.zone}/${local.project}/${service}"
    runtime = {
      schema_version  = 2
      service         = service
      project_id      = local.project
      zone            = var.zone
      region          = "europe-west1"
      service_account = "agora-${service}-${local.suffix}@${local.project}.iam.gserviceaccount.com"
      repositories    = { agora-production = "europe-west1-docker.pkg.dev/${local.project}/agora-${service}-${local.suffix}-production" }
    }
    database        = jsondecode(module.handoff.cases[replace(service, "-", "_")].document_json)
    database_source = module.handoff.cases[replace(service, "-", "_")].reference
  } }
  cases = merge(local.documents, {
    peer_scope      = merge(local.documents.json-keys, { scope = local.documents.authentication.scope })
    peer_runtime    = merge(local.documents.json-keys, { runtime = local.documents.authentication.runtime })
    no_database     = merge(local.documents.json-keys, { database = null })
    peer_database   = merge(local.documents.json-keys, { database = local.documents.authentication.database })
    public_database = merge(local.documents.json-keys, { database = merge(local.documents.json-keys.database, { project_id = "agora-public-api-test" }) })
    missing_source  = merge(local.documents.json-keys, { database_source = null })
    peer_source     = merge(local.documents.json-keys, { database_source = local.documents.authentication.database_source })
    latest_source   = merge(local.documents.json-keys, { database_source = merge(local.documents.json-keys.database_source, { generation = "latest" }) })
    legacy_schema   = merge(local.documents.json-keys, { schema_version = 1 })
    api_runtime     = merge(local.documents.json-keys, { runtime = merge(local.documents.json-keys.runtime, { zone = "public-api" }) })
    peer_registry   = merge(local.documents.json-keys, { runtime = merge(local.documents.json-keys.runtime, { repositories = local.documents.authentication.runtime.repositories }) })
    peer_project    = merge(local.documents.json-keys, { runtime = merge(local.documents.json-keys.runtime, { project_id = "agora-peer-test" }) })
  })
}

output "cases" {
  value = { for name, document in local.cases : name => {
    foundation_json = jsonencode(document)
    foundation = {
      schema_version = 2
      bucket         = "agora-management-test-123456789012-tofu-state"
      object         = "foundation/coordinates/workloads/production/${var.zone}/${local.project}/${name == "authentication" ? "authentication" : "json-keys"}/${sha256(jsonencode(document))}.json"
      generation     = "987654321"
      sha256         = sha256(jsonencode(document))
    }
  } }
}

output "api" {
  value = { for service in keys(local.documents) : service => {
    image            = "europe-west1-docker.pkg.dev/${local.project}/agora-${service}-${local.suffix}-production/service-${service}/${local.role}@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    revision         = "agora-${service}-${local.role}-candidate"
    serving_revision = "agora-${service}-${local.role}-active"
  } }
}

output "authentication" {
  value = {
    json_keys_host     = "agora-json-keys-grpc-123456.europe-west1.run.app"
    platform_auth_url  = "https://auth.example.test"
    smtp_address       = "smtp.example.test:587"
    smtp_username      = "example"
    smtp_sender_domain = "example.test"
    smtp_sender_email  = "noreply@example.test"
    smtp_sender_name   = "Example"
  }
}
