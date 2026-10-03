locals {
  database = {
    schema_version = 2
    service        = "json-keys"
    project_id     = "agora-private-test"
    zone           = "europe-west1-b"
    private_ip     = "10.20.0.5"
    port           = 5432
  }
  documents = merge({
    json_keys      = jsonencode(local.database)
    authentication = jsonencode(merge(local.database, { service = "authentication", private_ip = "10.20.0.6", port = 5433 }))
    malformed      = "not JSON"
    extra_field    = jsonencode(merge(local.database, { password = "synthetic-forbidden-field" }))
    }, { for name, mutation in {
      peer_service = { service = "authentication" }
      peer_project = { project_id = "agora-peer-test" }
      peer_zone    = { zone = "us-central1-a" }
      peer_port    = { port = 5433 }
      schema       = { schema_version = 1 }
      public_ip    = { private_ip = "8.8.8.8" }
      invalid_ip   = { private_ip = "10.999.0.1" }
    } : name => jsonencode(merge(local.database, mutation)) }
  )
}

output "cases" {
  # Matching hashes force negative cases to exercise the contract itself.
  value = { for name, document in local.documents : name => {
    private_project_id = "agora-private-test"
    document_json      = document
    reference = {
      schema_version = 2
      bucket         = "agora-management-test-123456789012-tofu-state"
      object         = "foundation/database-coordinates/production/agora-private-test/${name == "authentication" ? "authentication" : "json-keys"}/${sha256(document)}.json"
      generation     = "123456789"
      sha256         = sha256(document)
    }
  } }
}
