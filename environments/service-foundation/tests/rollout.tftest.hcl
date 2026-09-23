mock_provider "google" {
  mock_data "google_project" { defaults = { number = "123456789012" } }
  mock_resource "google_service_account" {
    defaults = {
      email = "mock-account@agora-json-keys-test.iam.gserviceaccount.com"
      name  = "projects/agora-json-keys-test/serviceAccounts/mock-account@agora-json-keys-test.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id              = "agora-json-keys-test"
  region                  = "europe-west1"
  name                    = "agora-json-keys-grpc"
  runtime_service_account = "agora-json-keys@agora-json-keys-test.iam.gserviceaccount.com"
  artifact_bucket         = "agora-json-keys-test-deploy-artifacts"
  receipt_bucket          = "agora-management-test-deployment-receipts"
  verification_image      = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-tooling/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  notification_channels = [
    "projects/agora-json-keys-test/notificationChannels/123456789",
  ]
  probe = {
    network    = "projects/agora-network-test/global/networks/agora-production"
    subnetwork = "projects/agora-network-test/regions/europe-west1/subnetworks/agora-production-europe-west1"
  }
}

run "inactive_service_rollout" {
  command = plan

  module {
    source = "../../modules/cloud-run-rollout"
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
            EXPECTED_PROBE_ACCOUNT  = google_service_account.execution["probe"].email
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
          toset(config.usages) == toset(["VERIFY"]) && config.service_account == google_service_account.execution["verify"].email :
          toset(config.usages) == toset(["RENDER", "DEPLOY"]) && config.service_account == google_service_account.execution["deploy"].email
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
        task.service_account == google_service_account.execution["probe"].email && task.max_retries == 0 && task.timeout == "90s" &&
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

run "execution_authority" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }

  assert {
    condition = { for key, role in google_project_iam_custom_role.execution : key => role.permissions } == {
      submit = toset([
        "clouddeploy.config.get", "clouddeploy.deliveryPipelines.get", "clouddeploy.jobRuns.get",
        "clouddeploy.operations.get", "clouddeploy.releases.create", "clouddeploy.releases.get",
        "clouddeploy.rollouts.create", "clouddeploy.rollouts.get", "clouddeploy.targets.get",
      ])
      deploy = toset([
        "clouddeploy.config.get", "logging.logEntries.create", "run.operations.get", "run.revisions.get",
        "run.services.create", "run.services.get", "run.services.update",
      ])
      verify = toset([
        "clouddeploy.config.get", "clouddeploy.jobRuns.get", "clouddeploy.releases.get", "clouddeploy.rollouts.get",
        "logging.logEntries.create", "run.operations.get", "run.revisions.get", "run.services.get",
      ])
      probe = toset(["run.routes.invoke"])
    }
    error_message = "Keep project permissions separate: submit, deploy, read-only verification, and API-only invocation."
  }

  assert {
    condition = (
      { for key, account in google_service_account.execution : key => [account.project, account.account_id] } == {
        deploy = [var.project_id, "rollout-deploy"]
        verify = [var.project_id, "rollout-verify"]
        probe  = [var.project_id, "rollout-probe"]
      } &&
      alltrue([for key, binding in google_project_iam_member.execution :
        binding.project == var.project_id &&
        binding.role == google_project_iam_custom_role.execution[key].name &&
        binding.member == "serviceAccount:${key == "submit" ? "infra-release@${var.project_id}.iam.gserviceaccount.com" : google_service_account.execution[key].email}"
      ])
    )
    error_message = "Create distinct service-project identities and bind each project role only to its owner."
  }

  assert {
    condition = (
      toset(keys(google_service_account_iam_member.submit_execution)) == toset(["deploy", "verify"]) &&
      alltrue([for key, binding in google_service_account_iam_member.submit_execution :
        binding.service_account_id == google_service_account.execution[key].name &&
        binding.member == "serviceAccount:infra-release@${var.project_id}.iam.gserviceaccount.com" &&
        binding.role == "roles/iam.serviceAccountUser"
      ]) &&
      [google_service_account_iam_member.deploy_runtime.service_account_id,
        google_service_account_iam_member.deploy_runtime.member,
        google_service_account_iam_member.deploy_runtime.role] == [
        "projects/${var.project_id}/serviceAccounts/${var.runtime_service_account}",
        "serviceAccount:${google_service_account.execution["deploy"].email}", "roles/iam.serviceAccountUser",
      ]
    )
    error_message = "Only the submitter may attach execution accounts; only the deploy worker may attach the application account."
  }

  assert {
    condition = (
      google_project_iam_custom_role.probe_execution.permissions == toset(["run.jobs.get", "run.jobs.run", "run.jobs.runWithOverrides"]) &&
      [google_cloud_run_v2_job_iam_member.probe_execution.project,
        google_cloud_run_v2_job_iam_member.probe_execution.location,
        google_cloud_run_v2_job_iam_member.probe_execution.name,
        google_cloud_run_v2_job_iam_member.probe_execution.role,
        google_cloud_run_v2_job_iam_member.probe_execution.member] == [
        var.project_id, var.region, google_cloud_run_v2_job.probe.name,
        google_project_iam_custom_role.probe_execution.name, "serviceAccount:${google_service_account.execution["verify"].email}",
      ]
    )
    error_message = "Grant job execution with overrides to the verifier on the exact probe, never project-wide."
  }

  assert {
    condition = { for key, binding in google_artifact_registry_repository_iam_member.execution : key => [
      binding.project, binding.location, binding.repository, binding.role, binding.member,
      ] } == {
      deploy = [var.project_id, var.region, "agora-production", "roles/artifactregistry.reader", "serviceAccount:${google_service_account.execution["deploy"].email}"]
      verify = [var.project_id, var.region, "agora-tooling", "roles/artifactregistry.reader", "serviceAccount:${google_service_account.execution["verify"].email}"]
    }
    error_message = "Keep image access read-only on the application and verifier repositories, not the project."
  }
}

run "private_artifact_storage" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }

  assert {
    condition = {
      project       = google_storage_bucket.artifacts.project
      name          = google_storage_bucket.artifacts.name
      location      = google_storage_bucket.artifacts.location
      uniform       = google_storage_bucket.artifacts.uniform_bucket_level_access
      public_access = google_storage_bucket.artifacts.public_access_prevention
      force_destroy = google_storage_bucket.artifacts.force_destroy
      versioning    = google_storage_bucket.artifacts.versioning[0].enabled
      soft_delete   = google_storage_bucket.artifacts.soft_delete_policy[0].retention_duration_seconds
      expiry_rules  = length(google_storage_bucket.artifacts.lifecycle_rule)
      } == {
      project    = var.project_id, name = var.artifact_bucket, location = var.region,
      uniform    = true, public_access = "enforced", force_destroy = false,
      versioning = true, soft_delete = 604800, expiry_rules = 0,
    }
    error_message = "Retain private service-project artifacts without automatic expiry or destructive bucket cleanup."
  }

  assert {
    condition = { for key, binding in google_storage_bucket_iam_member.artifacts : key => [binding.bucket, binding.role, binding.member] } == {
      deploy_creator = [var.artifact_bucket, "roles/storage.objectCreator", "serviceAccount:${google_service_account.execution["deploy"].email}"]
      deploy_reader  = [var.artifact_bucket, "roles/storage.objectViewer", "serviceAccount:${google_service_account.execution["deploy"].email}"]
      verify_creator = [var.artifact_bucket, "roles/storage.objectCreator", "serviceAccount:${google_service_account.execution["verify"].email}"]
      verify_reader  = [var.artifact_bucket, "roles/storage.objectViewer", "serviceAccount:${google_service_account.execution["verify"].email}"]
    }
    error_message = "Execution workers may create/read artifact objects but cannot overwrite/delete them or write receipts."
  }

  assert {
    condition = (
      google_storage_managed_folder.source.bucket == var.receipt_bucket &&
      google_storage_managed_folder.source.name == "services/${var.project_id}/production/sources/" &&
      !google_storage_managed_folder.source.force_destroy &&
      google_storage_managed_folder.source.deletion_policy == "PREVENT" &&
      { for key, binding in google_storage_managed_folder_iam_member.source : key => [
        binding.bucket, binding.managed_folder, binding.role, binding.member,
        ] } == {
        deploy        = [var.receipt_bucket, "services/${var.project_id}/production/sources/", "roles/storage.objectViewer", "serviceAccount:${google_service_account.execution["deploy"].email}"]
        service_agent = [var.receipt_bucket, "services/${var.project_id}/production/sources/", "roles/storage.objectViewer", "serviceAccount:service-123456789012@gcp-sa-clouddeploy.iam.gserviceaccount.com"]
      }
    )
    error_message = "Only render/deploy and the service's Cloud Deploy agent may read the retained source folder, not sibling receipts."
  }
}

run "native_rollout_alerts" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }

  assert {
    condition = alltrue([for policy in google_monitoring_alert_policy.rollout :
      {
        project    = policy.project
        enabled    = policy.enabled
        channels   = toset(policy.notification_channels)
        combiner   = policy.combiner
        conditions = length(policy.conditions)
        rate_limit = policy.alert_strategy[0].notification_rate_limit[0].period
        auto_close = policy.alert_strategy[0].auto_close
        prompts    = policy.alert_strategy[0].notification_prompts
        } == {
        project    = "agora-json-keys-test"
        enabled    = true
        channels   = toset(["projects/agora-json-keys-test/notificationChannels/123456789"])
        combiner   = "OR"
        conditions = 1
        rate_limit = "300s"
        auto_close = "604800s"
        prompts    = tolist(["OPENED"])
      }
    ])
    error_message = "Native alerts need operations delivery, bounded notifications, and no misleading recovery notifications."
  }

  assert {
    condition = alltrue([for key, policy in google_monitoring_alert_policy.rollout :
      slice(split("\n", policy.conditions[0].condition_matched_log[0].filter), 0, 4) == tolist([
        "logName=\"projects/agora-json-keys-test/logs/clouddeploy.googleapis.com%2F${key == "render_failed" ? "release_render" : "rollout_update"}\"",
        "resource.type=\"clouddeploy.googleapis.com/DeliveryPipeline\"",
        "resource.labels.pipeline_id=\"agora-json-keys-grpc\"",
        "resource.labels.location=\"europe-west1\"",
      ]) &&
      policy.conditions[0].condition_matched_log[0].label_extractors == tomap(merge(
        { release = "EXTRACT(jsonPayload.release)" },
        key == "render_failed" ? {} : { rollout = "EXTRACT(jsonPayload.rollout)" },
      ))
    ])
    error_message = "Scope alerts to the exact pipeline, region and project; extract identities without log message payloads."
  }

  assert {
    condition = { for key, policy in google_monitoring_alert_policy.rollout : key => {
      predicates = slice(
        split("\n", policy.conditions[0].condition_matched_log[0].filter), 4,
        length(split("\n", policy.conditions[0].condition_matched_log[0].filter)),
      )
      severity = policy.severity
      } } == {
      render_failed = {
        predicates = tolist(["jsonPayload.releaseRenderState=\"FAILED\""])
        severity   = "ERROR"
      }
      rollout_failed = {
        predicates = tolist(["jsonPayload.rolloutUpdateType=(\"FAILED\" OR \"CANCELLED\" OR \"HALTED\" OR \"REJECTED\")"])
        severity   = "ERROR"
      }
      approval_required = {
        predicates = tolist(["jsonPayload.rolloutUpdateType=\"APPROVAL_REQUIRED\""])
        severity   = "WARNING"
      }
      advance_required = {
        predicates = tolist(["jsonPayload.rolloutUpdateType=\"ADVANCE_REQUIRED\""])
        severity   = "WARNING"
      }
    }
    error_message = "Keep failures distinct from expected approval and advancement events, using Google's platform log fields."
  }
}

run "reject_missing_operations_channel" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables { notification_channels = [] }
  expect_failures = [var.notification_channels]
}

run "reject_peer_operations_channel" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables { notification_channels = ["projects/agora-authentication-test/notificationChannels/123456789"] }
  expect_failures = [var.notification_channels]
}

run "reject_peer_application_identity" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables {
    runtime_service_account = "agora-authentication@agora-authentication-test.iam.gserviceaccount.com"
  }
  expect_failures = [var.runtime_service_account]
}

run "reject_privileged_application_identity" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables {
    runtime_service_account = "rollout-deploy@agora-json-keys-test.iam.gserviceaccount.com"
  }
  expect_failures = [var.runtime_service_account]
}

run "reject_floating_verifier" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables {
    verification_image = "europe-west1-docker.pkg.dev/agora-json-keys-test/agora-production/verify:latest"
  }
  expect_failures = [var.verification_image]
}

run "reject_peer_verifier" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables {
    verification_image = "europe-west1-docker.pkg.dev/agora-authentication-test/agora-production/verify@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }
  expect_failures = [var.verification_image]
}

run "reject_region_pattern_injection" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables {
    region = "europe-west1|.*"
  }
  expect_failures = [var.region]
}

run "reject_artifacts_in_receipt_bucket" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables {
    artifact_bucket = "agora-management-test-deployment-receipts"
  }
  expect_failures = [var.receipt_bucket]
}

run "reject_mismatched_probe_network" {
  command = plan
  module { source = "../../modules/cloud-run-rollout" }
  variables {
    probe = {
      network    = "projects/agora-authentication-test/global/networks/agora-authentication"
      subnetwork = "projects/agora-json-keys-test/regions/europe-west1/subnetworks/agora-json-keys"
    }
  }
  expect_failures = [var.probe]
}
