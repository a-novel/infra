module "handoff" {
  source = "../../../../service-foundation/tests/fixtures/handoff"
}

locals {
  documents = { for service in ["json-keys", "authentication"] : service => {
    schema_version = 2
    scope          = "workloads/production/private/agora-private-test/${service}"
    runtime = {
      schema_version  = 2
      service         = service
      project_id      = "agora-private-test"
      zone            = "private"
      region          = "europe-west1"
      service_account = "agora-${service}-private@agora-private-test.iam.gserviceaccount.com"
      repositories    = { agora-production = "europe-west1-docker.pkg.dev/agora-private-test/agora-${service}-private-production" }
    }
    database        = jsondecode(module.handoff.cases[replace(service, "-", "_")].document_json)
    database_source = module.handoff.cases[replace(service, "-", "_")].reference
    rollout         = null
  } }
  cases = merge(local.documents, {
    peer_scope      = merge(local.documents.json-keys, { scope = "workloads/production/private/agora-private-test/authentication" })
    peer_runtime    = merge(local.documents.json-keys, { runtime = local.documents.authentication.runtime })
    no_database     = merge(local.documents.json-keys, { database = null })
    peer_database   = merge(local.documents.json-keys, { database = local.documents.authentication.database })
    public_database = merge(local.documents.json-keys, { database = merge(local.documents.json-keys.database, { project_id = "agora-api-test" }) })
    missing_source  = merge(local.documents.json-keys, { database_source = null })
    peer_source     = merge(local.documents.json-keys, { database_source = local.documents.authentication.database_source })
    latest_source   = merge(local.documents.json-keys, { database_source = merge(local.documents.json-keys.database_source, { generation = "latest" }) })
    legacy_schema   = merge(local.documents.json-keys, { schema_version = 1 })
    api_runtime     = merge(local.documents.json-keys, { runtime = merge(local.documents.json-keys.runtime, { zone = "public-api" }) })
    peer_registry   = merge(local.documents.json-keys, { runtime = merge(local.documents.json-keys.runtime, { repositories = local.documents.authentication.runtime.repositories }) })
  })
}

output "cases" {
  value = { for name, document in local.cases : name => {
    foundation_json = jsonencode(document)
    foundation = {
      schema_version = 2
      bucket         = "agora-management-test-123456789012-tofu-state"
      object         = "foundation/coordinates/workloads/production/private/agora-private-test/${name == "authentication" ? "authentication" : "json-keys"}/${sha256(jsonencode(document))}.json"
      generation     = "987654321"
      sha256         = sha256(jsonencode(document))
    }
  } }
}
