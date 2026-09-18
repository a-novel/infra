mock_provider "google" {}

variables {
  project_id = "agora-json-keys-test"
  region     = "europe-west1"
  name       = "agora-json-keys-grpc"
  execution_service_accounts = {
    deploy = "rollout-deploy@agora-json-keys-test.iam.gserviceaccount.com"
    verify = "rollout-verify@agora-json-keys-test.iam.gserviceaccount.com"
  }
  artifact_bucket    = "agora-json-keys-test-deploy-artifacts"
  verification_image = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  probe = {
    service_account = "rollout-probe@agora-json-keys-test.iam.gserviceaccount.com"
    network         = "projects/agora-network-test/global/networks/agora-production"
    subnetwork      = "projects/agora-network-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
  }
}

run "inactive_service_rollout" {
  command = plan

  module {
    source = "../../../modules/cloud-run-rollout"
  }

  assert {
    condition = (
      google_clouddeploy_target.service.project == var.project_id &&
      google_clouddeploy_target.service.location == var.region &&
      google_clouddeploy_target.service.name == var.name &&
      google_clouddeploy_target.service.run[0].location == "projects/${var.project_id}/locations/${var.region}" &&
      google_clouddeploy_target.service.require_approval &&
      google_clouddeploy_target.service.deletion_policy == "PREVENT" &&
      google_clouddeploy_delivery_pipeline.service.project == var.project_id &&
      google_clouddeploy_delivery_pipeline.service.location == var.region &&
      google_clouddeploy_delivery_pipeline.service.name == var.name &&
      google_clouddeploy_delivery_pipeline.service.suspended &&
      google_clouddeploy_delivery_pipeline.service.deletion_policy == "PREVENT"
    )
    error_message = "The pilot must remain suspended and approval-gated inside one protected service project."
  }

  assert {
    condition = (
      length(google_clouddeploy_delivery_pipeline.service.serial_pipeline[0].stages) == 1 &&
      alltrue([for stage in google_clouddeploy_delivery_pipeline.service.serial_pipeline[0].stages :
        stage.target_id == var.name &&
        stage.strategy[0].canary[0].runtime_config[0].cloud_run[0].automatic_traffic_control &&
        stage.strategy[0].canary[0].canary_deployment[0].percentages == tolist([0]) &&
        stage.strategy[0].canary[0].runtime_config[0].cloud_run[0].canary_revision_tags == tolist(["candidate"]) &&
        stage.strategy[0].canary[0].runtime_config[0].cloud_run[0].stable_revision_tags == tolist(["stable"]) &&
        length(stage.strategy[0].canary[0].canary_deployment[0].predeploy) == 0 &&
        length(stage.strategy[0].canary[0].canary_deployment[0].postdeploy) == 0 &&
        length(stage.strategy[0].canary[0].canary_deployment[0].verify_config[0].tasks) == 1 &&
        alltrue([for task in stage.strategy[0].canary[0].canary_deployment[0].verify_config[0].tasks :
          task.container[0].image == var.verification_image &&
          task.container[0].env == tomap({
            EXPECTED_PROJECT_ID     = var.project_id
            EXPECTED_REGION         = var.region
            EXPECTED_SERVICE        = var.name
            EXPECTED_PROBE_ACCOUNT  = var.probe.service_account
            EXPECTED_VERIFIER_IMAGE = var.verification_image
            EXPECTED_PROBE_NETWORK  = var.probe.network
            EXPECTED_PROBE_SUBNET   = var.probe.subnetwork
          })
        ])
      ])
    )
    error_message = "Require a zero-percent candidate and pinned, scope-bound verification without mutation hooks."
  }

  assert {
    condition = (
      length(google_clouddeploy_target.service.execution_configs) == 2 &&
      alltrue([for config in google_clouddeploy_target.service.execution_configs :
        config.artifact_storage == "gs://${var.artifact_bucket}/cloud-deploy/${var.project_id}/${var.name}" &&
        config.execution_timeout == "600s" && !config.verbose &&
        (contains(config.usages, "VERIFY") ?
          toset(config.usages) == toset(["VERIFY"]) && config.service_account == var.execution_service_accounts.verify :
          toset(config.usages) == toset(["RENDER", "DEPLOY"]) && config.service_account == var.execution_service_accounts.deploy
        )
      ])
    )
    error_message = "Use separate bounded execution environments with explicit identities and service-scoped artifacts."
  }

  assert {
    condition = (
      google_cloud_run_v2_job.probe.project == var.project_id &&
      google_cloud_run_v2_job.probe.location == var.region &&
      google_cloud_run_v2_job.probe.deletion_protection &&
      google_cloud_run_v2_job.probe.template[0].task_count == 1 &&
      google_cloud_run_v2_job.probe.template[0].parallelism == 1 &&
      alltrue([for task in google_cloud_run_v2_job.probe.template[0].template :
        task.service_account == var.probe.service_account && task.max_retries == 0 && task.timeout == "90s" &&
        length(task.volumes) == 0 && length(task.containers) == 1 &&
        task.containers[0].image == var.verification_image &&
        task.containers[0].args == tolist(["probe"]) && length(task.containers[0].env) == 0 &&
        task.vpc_access[0].egress == "ALL_TRAFFIC" &&
        task.vpc_access[0].network_interfaces[0].network == var.probe.network &&
        task.vpc_access[0].network_interfaces[0].subnetwork == var.probe.subnetwork &&
        task.vpc_access[0].network_interfaces[0].tags == tolist(["agora-rollout-probe"])
      ])
    )
    error_message = "The single-attempt private probe must use a dedicated identity, API-only network tag, and no secrets."
  }
}

run "reject_peer_execution_identity" {
  command = plan
  module { source = "../../../modules/cloud-run-rollout" }
  variables {
    execution_service_accounts = {
      deploy = "rollout-deploy@agora-authentication-test.iam.gserviceaccount.com"
      verify = "rollout-verify@agora-json-keys-test.iam.gserviceaccount.com"
    }
  }
  expect_failures = [var.execution_service_accounts]
}

run "reject_shared_execution_identity" {
  command = plan
  module { source = "../../../modules/cloud-run-rollout" }
  variables {
    execution_service_accounts = {
      deploy = "rollout-deploy@agora-json-keys-test.iam.gserviceaccount.com"
      verify = "rollout-deploy@agora-json-keys-test.iam.gserviceaccount.com"
    }
  }
  expect_failures = [var.execution_service_accounts]
}

run "reject_floating_verifier" {
  command = plan
  module { source = "../../../modules/cloud-run-rollout" }
  variables {
    verification_image = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/verify:latest"
  }
  expect_failures = [var.verification_image]
}

run "reject_peer_verifier" {
  command = plan
  module { source = "../../../modules/cloud-run-rollout" }
  variables {
    verification_image = "europe-west1-docker.pkg.dev/agora-authentication-test/agora-production/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  expect_failures = [var.verification_image]
}

run "reject_region_pattern_injection" {
  command = plan
  module { source = "../../../modules/cloud-run-rollout" }
  variables {
    region = "europe-west1|.*"
  }
  expect_failures = [var.region]
}

run "reject_privileged_probe_identity" {
  command = plan
  module { source = "../../../modules/cloud-run-rollout" }
  variables {
    probe = {
      service_account = "rollout-deploy@agora-json-keys-test.iam.gserviceaccount.com"
      network         = "projects/agora-json-keys-test/global/networks/agora-json-keys"
      subnetwork      = "projects/agora-json-keys-test/regions/europe-west1/subnetworks/agora-json-keys"
    }
  }
  expect_failures = [var.probe]
}

run "reject_mismatched_probe_network" {
  command = plan
  module { source = "../../../modules/cloud-run-rollout" }
  variables {
    probe = {
      service_account = "rollout-probe@agora-json-keys-test.iam.gserviceaccount.com"
      network         = "projects/agora-authentication-test/global/networks/agora-authentication"
      subnetwork      = "projects/agora-json-keys-test/regions/europe-west1/subnetworks/agora-json-keys"
    }
  }
  expect_failures = [var.probe]
}
