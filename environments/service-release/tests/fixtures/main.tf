locals {
  json_keys = file("${path.module}/json-keys.json")
  documents = {
    json_keys       = local.json_keys
    authentication  = file("${path.module}/authentication.json")
    peer_runtime    = replace(local.json_keys, "agora-json-keys@agora-json-keys-test", "agora-authentication@agora-authentication-test")
    public_database = replace(local.json_keys, "10.20.0.5", "8.8.8.8")
    peer_database   = jsonencode(merge(jsondecode(local.json_keys), { database = jsondecode(file("${path.module}/authentication.json")).database }))
    no_database     = jsonencode(merge(jsondecode(local.json_keys), { database = null }))
    unsupported     = jsonencode(merge(jsondecode(local.json_keys), { schema_version = 2 }))
    malformed       = "not JSON"
  }
}

output "cases" {
  # Invalid documents receive matching hashes: each test must reach the contract
  # validation rather than passing solely because of a checksum mismatch.
  value = { for name, document in local.documents : name => {
    foundation_json = document
    foundation = {
      schema_version = 1
      bucket         = "agora-management-test-123456789012-tofu-state"
      object         = "foundation/coordinates/${name == "authentication" ? "agora-authentication-test" : "agora-json-keys-test"}/${sha256(document)}.json"
      generation     = "123456789"
      sha256         = sha256(document)
    }
  } }
}
