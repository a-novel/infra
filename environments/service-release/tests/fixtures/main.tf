locals {
  json_keys = file("${path.module}/json-keys.json")
  rollout = {
    pipeline = "projects/agora-json-keys-test/locations/europe-west1/deliveryPipelines/agora-json-keys-grpc"
    target   = "projects/agora-json-keys-test/locations/europe-west1/targets/agora-json-keys-grpc"
  }
  rollout_cases = {
    rollout         = local.rollout
    numeric_rollout = { for field, name in local.rollout : field => replace(name, "agora-json-keys-test", "123456") }
    peer_pipeline   = merge(local.rollout, { pipeline = replace(local.rollout.pipeline, "agora-json-keys-test", "agora-peer-test") })
    peer_target     = merge(local.rollout, { target = replace(local.rollout.target, "europe-west1", "europe-west2") })
  }
  documents = merge({
    json_keys       = local.json_keys
    authentication  = file("${path.module}/authentication.json")
    peer_runtime    = replace(local.json_keys, "agora-json-keys@agora-json-keys-test", "agora-authentication@agora-authentication-test")
    public_database = replace(local.json_keys, "10.20.0.5", "8.8.8.8")
    peer_database   = jsonencode(merge(jsondecode(local.json_keys), { database = jsondecode(file("${path.module}/authentication.json")).database }))
    no_database     = jsonencode(merge(jsondecode(local.json_keys), { database = null }))
    unsupported     = jsonencode(merge(jsondecode(local.json_keys), { schema_version = 2 }))
    malformed       = "not JSON"
    authentication_rollout = jsonencode(merge(jsondecode(file("${path.module}/authentication.json")), {
      rollout = { for field, name in local.rollout : field => replace(name, "agora-json-keys-test", "agora-authentication-test") }
    }))
    }, { for name, rollout in local.rollout_cases : name =>
    jsonencode(merge(jsondecode(local.json_keys), { rollout = rollout }))
  })
}

output "rollout_input" {
  value = {
    project_number   = "123456"
    image            = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/service-json-keys/grpc@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    release_id       = "release-1"
    request_id       = "11111111-2222-4333-8444-555555555555"
    source_commit    = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    skaffold_version = "2.17.1"
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
      object         = "foundation/coordinates/${startswith(name, "authentication") ? "agora-authentication-test" : "agora-json-keys-test"}/${sha256(document)}.json"
      generation     = "123456789"
      sha256         = sha256(document)
    }
  } }
}
