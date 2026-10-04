mock_provider "google" {
  mock_data "google_project" { defaults = { number = "123456789012" } }
  mock_resource "google_service_account" {
    defaults = {
      email = "mock-account@agora-private-test.iam.gserviceaccount.com"
      name  = "projects/agora-private-test/serviceAccounts/mock-account@agora-private-test.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id                 = "agora-private-test"
  scope                      = { service = "json-keys", zone = "private" }
  foundation_service_account = "infra-foundation@agora-management-test.iam.gserviceaccount.com"
  region                     = "europe-west1"
  name                       = "agora-json-keys-grpc"
  runtime_service_account    = "agora-json-keys-private@agora-private-test.iam.gserviceaccount.com"
  artifact_bucket            = "agora-private-test-json-keys-private-rollout"
  receipt_bucket             = "agora-management-test-deployment-receipts"
  verification_image         = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-private-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  notification_channels      = ["projects/agora-private-test/notificationChannels/123456789"]
  probe = {
    network    = "projects/agora-private-test/global/networks/agora-production"
    subnetwork = "projects/agora-private-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
  }
}

run "private_json_keys_authority" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }

  assert {
    condition = alltrue([for stage in google_clouddeploy_delivery_pipeline.service.serial_pipeline[0].stages :
      alltrue([for task in stage.strategy[0].canary[0].canary_deployment[0].verify_config[0].tasks :
        task.container[0].env["EXPECTED_ZONE"] == "private" &&
        task.container[0].env["EXPECTED_SERVICE"] == "agora-json-keys-grpc"
      ])
    ])
    error_message = "Protected verification must bind the private zone and exact gRPC service."
  }

  assert {
    condition = (
      { for key, account in google_service_account.execution : key => account.account_id } == {
        deploy = "deploy-json-keys-private", verify = "verify-json-keys-private", probe = "probe-json-keys-private",
      } &&
      alltrue([for key, binding in google_service_account_iam_member.submit_execution :
        binding.member == "serviceAccount:infra-json-keys-private@agora-private-test.iam.gserviceaccount.com" &&
        binding.service_account_id == google_service_account.execution[key].name
      ]) &&
      google_service_account_iam_member.deploy_runtime.service_account_id == "projects/agora-private-test/serviceAccounts/agora-json-keys-private@agora-private-test.iam.gserviceaccount.com"
    )
    error_message = "Workers, submitter and attached runtime must belong to exactly JSON Keys/private."
  }

  assert {
    condition = (
      { for key, role in google_project_iam_custom_role.execution : key => role.role_id } == {
        submit = "agoraRolloutSubmit_json_keys_private",
        deploy = "agoraRolloutDeploy_json_keys_private",
        verify = "agoraRolloutVerify_json_keys_private",
      } &&
      alltrue([for role in concat(values(google_project_iam_custom_role.pipeline), values(google_project_iam_custom_role.service), [google_project_iam_custom_role.target, google_project_iam_custom_role.probe_execution]) :
        endswith(role.role_id, "_json_keys_private") && length(role.role_id) <= 64
      ]) &&
      toset(keys(google_project_iam_member.execution)) == toset(["submit", "deploy", "verify"]) &&
      alltrue([for binding in google_project_iam_member.execution :
        binding.project == var.project_id &&
        contains([for role in google_project_iam_custom_role.execution : role.name], binding.role)
      ])
    )
    error_message = "Shared role IDs must not collide; only the three minimal supporting roles are project-bound."
  }

  assert {
    condition = (
      alltrue([for key, binding in google_cloud_run_v2_service_iam_member.execution :
        binding.project == var.project_id && binding.location == var.region && binding.name == var.name &&
        binding.role == google_project_iam_custom_role.service[key].name &&
        binding.member == "serviceAccount:${key == "submit" ? "infra-json-keys-private@agora-private-test.iam.gserviceaccount.com" : google_service_account.execution[key].email}"
      ]) &&
      alltrue([for key, binding in google_clouddeploy_delivery_pipeline_iam_member.execution :
        binding.project == var.project_id && binding.location == var.region && binding.name == var.name &&
        binding.role == google_project_iam_custom_role.pipeline[key].name &&
        binding.member == "serviceAccount:${key == "submit" ? "infra-json-keys-private@agora-private-test.iam.gserviceaccount.com" : google_service_account.execution[key].email}"
      ]) &&
      google_clouddeploy_target_iam_member.submit.name == var.name &&
      google_clouddeploy_target_iam_member.submit.member == "serviceAccount:infra-json-keys-private@agora-private-test.iam.gserviceaccount.com"
    )
    error_message = "Application and pipeline authority must be bound to the selected native resource, not its shared project."
  }

  assert {
    condition = (
      google_clouddeploy_delivery_pipeline.service.suspended && google_clouddeploy_target.service.require_approval &&
      google_storage_bucket.artifacts.name == "agora-private-test-json-keys-private-rollout" &&
      google_storage_managed_folder.source.name == "workloads/production/private/agora-private-test/json-keys/production/sources/" &&
      alltrue([for binding in google_storage_managed_folder_iam_member.source :
        binding.managed_folder == google_storage_managed_folder.source.name && binding.role == "roles/storage.objectViewer"
      ]) &&
      google_artifact_registry_repository_iam_member.execution["deploy"].repository == "agora-json-keys-private-production" &&
      google_artifact_registry_repository_iam_member.execution["verify"].repository == "agora-json-keys-private-tooling"
    )
    error_message = "The inactive pipeline must keep source, artifacts and image readers inside the exact workload scope."
  }
}

run "public_authentication_authority" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables {
    scope                   = { service = "authentication", zone = "public-api" }
    name                    = "agora-authentication-rest"
    runtime_service_account = "agora-authentication-api@agora-private-test.iam.gserviceaccount.com"
    artifact_bucket         = "agora-private-test-authentication-api-rollout"
    verification_image      = "europe-west1-docker.pkg.dev/agora-private-test/agora-authentication-api-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  assert {
    condition = alltrue([for stage in google_clouddeploy_delivery_pipeline.service.serial_pipeline[0].stages :
      alltrue([for task in stage.strategy[0].canary[0].canary_deployment[0].verify_config[0].tasks :
        task.container[0].env["EXPECTED_ZONE"] == "public-api" &&
        task.container[0].env["EXPECTED_SERVICE"] == "agora-authentication-rest"
      ])
    ])
    error_message = "Protected verification must bind Authentication REST to the API zone."
  }

  assert {
    condition = (
      { for key, account in google_service_account.execution : key => account.account_id } == {
        deploy = "deploy-authentication-api", verify = "verify-authentication-api", probe = "probe-authentication-api",
      } &&
      alltrue([for role in concat(values(google_project_iam_custom_role.execution), values(google_project_iam_custom_role.pipeline), values(google_project_iam_custom_role.service), [google_project_iam_custom_role.target, google_project_iam_custom_role.probe_execution]) :
        endswith(role.role_id, "_authentication_api") && length(role.role_id) <= 64
      ]) &&
      google_cloud_run_v2_service_iam_member.execution["submit"].member == "serviceAccount:infra-authentication-api@agora-private-test.iam.gserviceaccount.com" &&
      google_cloud_run_v2_service_iam_member.execution["deploy"].name == "agora-authentication-rest" &&
      google_storage_managed_folder.source.name == "workloads/production/public-api/agora-private-test/authentication/production/sources/" &&
      google_artifact_registry_repository_iam_member.execution["deploy"].repository == "agora-authentication-api-production" &&
      google_artifact_registry_repository_iam_member.execution["verify"].repository == "agora-authentication-api-tooling" &&
      google_clouddeploy_delivery_pipeline.service.suspended
    )
    error_message = "Authentication/API definitions must not reuse JSON Keys identities, roles, storage or image access in the same project."
  }
}

run "public_json_keys_authority" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables {
    scope                   = { service = "json-keys", zone = "public-api" }
    name                    = "agora-json-keys-rest"
    runtime_service_account = "agora-json-keys-api@agora-private-test.iam.gserviceaccount.com"
    artifact_bucket         = "agora-private-test-json-keys-api-rollout"
    verification_image      = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-api-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  assert {
    condition = alltrue([for stage in google_clouddeploy_delivery_pipeline.service.serial_pipeline[0].stages :
      alltrue([for task in stage.strategy[0].canary[0].canary_deployment[0].verify_config[0].tasks :
        task.container[0].env["EXPECTED_ZONE"] == "public-api" &&
        task.container[0].env["EXPECTED_SERVICE"] == "agora-json-keys-rest"
      ])
    ])
    error_message = "Protected verification must bind JSON Keys REST to the API zone."
  }
  assert {
    condition = (
      google_service_account.execution["deploy"].account_id == "deploy-json-keys-api" &&
      google_cloud_run_v2_service_iam_member.execution["deploy"].name == "agora-json-keys-rest" &&
      google_service_account_iam_member.deploy_runtime.service_account_id == "projects/agora-private-test/serviceAccounts/agora-json-keys-api@agora-private-test.iam.gserviceaccount.com" &&
      google_storage_managed_folder.source.name == "workloads/production/public-api/agora-private-test/json-keys/production/sources/" &&
      google_artifact_registry_repository_iam_member.execution["deploy"].repository == "agora-json-keys-api-production" &&
      alltrue([for role in google_project_iam_custom_role.service : endswith(role.role_id, "_json_keys_api")])
    )
    error_message = "JSON Keys REST must use its API identity, custody and roles, never the private component's master-key-bearing runtime."
  }
}

run "private_authentication_identity_limits" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables {
    scope                   = { service = "authentication", zone = "private" }
    name                    = "agora-authentication-grpc"
    runtime_service_account = "agora-authentication-private@agora-private-test.iam.gserviceaccount.com"
    artifact_bucket         = "agora-private-test-authentication-private-rollout"
    verification_image      = "europe-west1-docker.pkg.dev/agora-private-test/agora-authentication-private-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  assert {
    condition = alltrue([for key, account in google_service_account.execution :
      account.account_id == "${key}-authentication-private" && length(account.account_id) <= 30
    ])
    error_message = "The longest supported service/zone identities must fit Google's limit without truncation or collisions."
  }
}

run "reject_platform_authority" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables {
    scope                   = { service = "json-keys", zone = "public" }
    name                    = "agora-json-keys-rest"
    runtime_service_account = "agora-json-keys-public@agora-private-test.iam.gserviceaccount.com"
    artifact_bucket         = "agora-private-test-json-keys-public-rollout"
    verification_image      = "europe-west1-docker.pkg.dev/agora-private-test/agora-json-keys-public-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  expect_failures = [var.scope]
}

run "reject_peer_pipeline" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables { name = "agora-authentication-grpc" }
  expect_failures = [var.name]
}

run "reject_peer_runtime" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables { runtime_service_account = "agora-authentication-private@agora-private-test.iam.gserviceaccount.com" }
  expect_failures = [var.runtime_service_account]
}

run "reject_shared_worker_as_runtime" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables { runtime_service_account = "deploy-json-keys-private@agora-private-test.iam.gserviceaccount.com" }
  expect_failures = [var.runtime_service_account]
}

run "reject_peer_artifacts" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables { artifact_bucket = "agora-private-test-authentication-private-rollout" }
  expect_failures = [var.artifact_bucket]
}

run "reject_peer_tooling" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables { verification_image = "europe-west1-docker.pkg.dev/agora-private-test/agora-authentication-private-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  expect_failures = [var.verification_image]
}

run "reject_legacy_shared_tooling" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables { verification_image = "europe-west1-docker.pkg.dev/agora-private-test/agora-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
  expect_failures = [var.verification_image]
}
