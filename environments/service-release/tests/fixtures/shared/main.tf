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
    rollout = {
      pipeline = "projects/${local.project}/locations/europe-west1/deliveryPipelines/agora-${service}-${local.role}"
      target   = "projects/${local.project}/locations/europe-west1/targets/agora-${service}-${local.role}"
    }
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
    no_rollout      = merge(local.documents.json-keys, { rollout = null })
    peer_pipeline   = merge(local.documents.json-keys, { rollout = merge(local.documents.json-keys.rollout, { pipeline = local.documents.authentication.rollout.pipeline }) })
    peer_target     = merge(local.documents.json-keys, { rollout = merge(local.documents.json-keys.rollout, { target = local.documents.authentication.rollout.target }) })
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

locals {
  requests       = yamldecode(file("${path.module}/../../../../../internal/submission/testdata/sharedRequests.yaml"))
  authentication = local.requests["public-api/authentication"].release.deployParameters
}

output "rollout" {
  value = { for scope, request in local.requests : trimprefix(scope, "${var.zone}/") => {
    project_number   = "123456"
    image            = request.release.buildArtifacts[0].tag
    release_id       = request.releaseId
    request_id       = request.requestId
    source_commit    = request.release.annotations.source-commit
    skaffold_version = request.release.skaffoldVersion
  } if startswith(scope, "${var.zone}/") }
}

output "authentication" {
  value = {
    json_keys_host     = local.authentication.jsonKeysHost
    platform_auth_url  = local.authentication.platformAuthURL
    smtp_address       = local.authentication.smtpAddress
    smtp_username      = local.authentication.smtpUsername
    smtp_sender_domain = local.authentication.smtpSenderDomain
    smtp_sender_email  = local.authentication.smtpSenderEmail
    smtp_sender_name   = local.authentication.smtpSenderName
  }
}
