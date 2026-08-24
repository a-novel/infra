mock_provider "google" {
  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
  }

  mock_resource "google_service_account" {
    defaults = {
      email = "infra-mock@agora-management-test.iam.gserviceaccount.com"
      name  = "projects/agora-management-test/serviceAccounts/infra-mock@agora-management-test.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_iam_workload_identity_pool" {
    defaults = {
      name = "projects/123456789012/locations/global/workloadIdentityPools/github-actions"
    }
  }

  mock_resource "google_project_iam_custom_role" {
    defaults = {
      name = "projects/agora-management-test/roles/infraSecretMetadataAdmin"
    }
  }
}

variables {
  management_project_id = "agora-management-test"
  operator_principals   = ["group:infra-operators@example.com"]
}

run "builds_the_protected_management_plane" {
  command = plan

  assert {
    condition     = output.root_name == "bootstrap"
    error_message = "The bootstrap root identifier changed."
  }

  assert {
    condition     = output.region == "europe-west1"
    error_message = "The bootstrap region default changed."
  }

  assert {
    condition     = output.management_project_number == "123456789012"
    error_message = "The immutable project number is not propagated."
  }

  assert {
    condition = (
      length(google_project_service.management) == 9 &&
      contains(keys(google_project_service.management), "orgpolicy.googleapis.com")
    )
    error_message = "The complete management-plane API set is not retained in code."
  }

  assert {
    condition = (
      google_storage_bucket.state.location == "EU" &&
      google_storage_bucket.state.public_access_prevention == "enforced" &&
      google_storage_bucket.state.uniform_bucket_level_access &&
      google_storage_bucket.state.versioning[0].enabled &&
      google_storage_bucket.state.soft_delete_policy[0].retention_duration_seconds == 604800 &&
      !google_storage_bucket.state.force_destroy
    )
    error_message = "The state bucket lost a durability or public-access safeguard."
  }

  assert {
    condition = (
      length(google_storage_managed_folder.state) == 3 &&
      google_storage_managed_folder.state["bootstrap"].name == "bootstrap/" &&
      google_storage_managed_folder.state["foundation"].name == "foundation/" &&
      google_storage_managed_folder.state["release"].name == "release/"
    )
    error_message = "State roots no longer have three independent managed-folder boundaries."
  }

  assert {
    condition = (
      google_storage_bucket.backups.public_access_prevention == "enforced" &&
      google_storage_bucket.backups.soft_delete_policy[0].retention_duration_seconds == 0 &&
      !google_storage_bucket.backups.force_destroy &&
      google_storage_bucket.receipts.versioning[0].enabled
    )
    error_message = "Backup or receipt storage lost a public-access or durability safeguard."
  }

  assert {
    condition     = length(google_service_account.automation) == 4
    error_message = "Exactly four automation trust-boundary identities are required."
  }

  assert {
    condition = alltrue([
      for name, provider in google_iam_workload_identity_pool_provider.github :
      strcontains(provider.attribute_condition, "assertion.repository_owner_id == '131281268'") &&
      strcontains(provider.attribute_condition, "assertion.repository_id == '1344262359'") &&
      strcontains(provider.attribute_condition, "assertion.ref == 'refs/heads/master'") &&
      strcontains(provider.attribute_condition, "a-novel/infra/.github/workflows/${local.trust_boundaries[name].workflow_filename}@refs/heads/master") &&
      provider.attribute_mapping["attribute.trust_boundary"] == "'${name}'" &&
      provider.oidc[0].allowed_audiences == null
    ])
    error_message = "A GitHub provider lost its immutable repository, branch, workflow, boundary, or canonical-audience restriction."
  }

  assert {
    condition = (
      !strcontains(google_iam_workload_identity_pool_provider.github["plan"].attribute_condition, "assertion.environment") &&
      strcontains(google_iam_workload_identity_pool_provider.github["foundation"].attribute_condition, "assertion.environment == 'production-foundation'") &&
      strcontains(google_iam_workload_identity_pool_provider.github["release"].attribute_condition, "assertion.environment == 'production-release'") &&
      strcontains(google_iam_workload_identity_pool_provider.github["recovery"].attribute_condition, "assertion.environment == 'production-recovery'")
    )
    error_message = "Protected workflow environments no longer match the three approved trust boundaries."
  }

  assert {
    condition = alltrue([
      for binding in values(google_project_iam_member.automation) :
      !contains(["roles/owner", "roles/editor"], binding.role)
      ]) && alltrue([
      for binding in values(google_project_iam_member.operator) :
      !contains(["roles/owner", "roles/editor"], binding.role)
      ]) && alltrue([
      for key in keys(google_project_iam_member.automation) :
      startswith(key, "plan:") || startswith(key, "foundation:")
    ])
    error_message = "An automation identity received a primitive Owner or Editor role."
  }

  assert {
    condition = (
      google_storage_managed_folder_iam_member.release_state.managed_folder == "release/" &&
      length(google_storage_managed_folder_iam_member.plan_state) == 3 &&
      length(google_storage_managed_folder_iam_member.recovery_state) == 3
    )
    error_message = "State IAM no longer separates plan, release, and recovery authority."
  }

  assert {
    condition = (
      length(google_secret_manager_secret.application) == 7 &&
      alltrue([
        for secret in values(google_secret_manager_secret.application) :
        secret.deletion_protection &&
        secret.deletion_policy == "PREVENT" &&
        secret.version_destroy_ttl == "2592000s"
      ])
    )
    error_message = "Secret containers lost their expected count or recovery protections."
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.recovery) == 7
    error_message = "Recovery must retain explicit per-secret access."
  }

  assert {
    condition = toset([
      for binding in values(google_secret_manager_secret_iam_member.operator) : binding.role
      ]) == toset([
      "roles/secretmanager.secretAccessor",
      "roles/secretmanager.secretVersionManager",
    ])
    error_message = "Human operators need exact per-secret payload and reversible version-lifecycle access."
  }

  assert {
    condition = (
      length(google_project_iam_audit_config.management) == 5 &&
      alltrue([
        for config in values(google_project_iam_audit_config.management) :
        toset(config.audit_log_config[*].log_type) == toset(["ADMIN_READ", "DATA_READ", "DATA_WRITE"])
      ])
    )
    error_message = "Security-critical management services must retain complete targeted audit coverage."
  }
}

run "rejects_an_invalid_project_id" {
  command = plan

  variables {
    management_project_id = "INVALID"
  }

  expect_failures = [var.management_project_id]
}

run "rejects_a_service_account_operator" {
  command = plan

  variables {
    operator_principals = ["serviceAccount:infra@example.iam.gserviceaccount.com"]
  }

  expect_failures = [var.operator_principals]
}

run "rejects_a_non_eu_management_location" {
  command = plan

  variables {
    storage_location = "US"
  }

  expect_failures = [var.storage_location]
}
