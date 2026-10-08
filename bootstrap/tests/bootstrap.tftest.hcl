# Plans the committed production inputs against a mocked provider.
mock_provider "google" {
  mock_data "google_project" {
    defaults = { number = "232403541574" }
  }
  mock_resource "google_service_account" {
    defaults = {
      email  = "infra-mock@a-novel-management-prod.iam.gserviceaccount.com"
      member = "serviceAccount:infra-mock@a-novel-management-prod.iam.gserviceaccount.com"
      name   = "projects/a-novel-management-prod/serviceAccounts/infra-mock@a-novel-management-prod.iam.gserviceaccount.com"
    }
  }
  mock_resource "google_iam_workload_identity_pool" {
    defaults = { name = "projects/232403541574/locations/global/workloadIdentityPools/github-actions" }
  }
  mock_resource "google_project_iam_custom_role" {
    defaults = { name = "projects/a-novel-management-prod/roles/infraMock" }
  }
}

run "protects_state_and_backups" {
  command = plan

  assert {
    condition = alltrue([for bucket in concat([google_storage_bucket.state, google_storage_bucket.backups], values(google_storage_bucket.pgbackrest)) :
      bucket.public_access_prevention == "enforced" && bucket.uniform_bucket_level_access && !bucket.force_destroy
    ])
    error_message = "Management buckets must be private, uniformly controlled and never force-destroyed."
  }

  assert {
    condition = (
      google_storage_bucket.state.versioning[0].enabled &&
      google_storage_bucket.state.soft_delete_policy[0].retention_duration_seconds == 604800
    )
    error_message = "State must keep prior generations and a week of soft-deleted objects."
  }

  assert {
    condition = alltrue([for bucket in google_storage_bucket.pgbackrest :
      bucket.versioning[0].enabled && tonumber(bucket.retention_policy[0].retention_period) == 604800 &&
      alltrue([for rule in bucket.lifecycle_rule : rule.condition[0].age == null || rule.condition[0].age == 0])
    ])
    error_message = "Backup repositories keep a week of retention and are never pruned by age; pgBackRest owns expiry."
  }

  assert {
    condition = alltrue([for secret in google_secret_manager_secret.application :
      secret.deletion_protection && secret.version_destroy_ttl == "2592000s"
    ])
    error_message = "Secrets must refuse deletion and keep destroyed versions recoverable for 30 days."
  }
}

run "trusts_only_reviewed_workflows" {
  command = plan

  assert {
    condition = (
      google_iam_workload_identity_pool_provider.github["plan"].attribute_condition == join("", [
        "assertion.repository_owner_id == '131281268' && assertion.repository_id == '1344262359' && (",
        "(assertion.ref == 'refs/heads/master' && assertion.workflow_ref == 'a-novel/infra/.github/workflows/drift.yaml@refs/heads/master') || ",
        "(assertion.event_name == 'pull_request' && assertion.base_ref == 'master' && ",
        "assertion.workflow_ref.startsWith('a-novel/infra/.github/workflows/main.yaml@refs/pull/')))",
      ]) &&
      google_iam_workload_identity_pool_provider.github["foundation"].attribute_condition == join("", [
        "assertion.repository_owner_id == '131281268' && assertion.repository_id == '1344262359' && (",
        "(assertion.ref == 'refs/heads/master' && assertion.workflow_ref == 'a-novel/infra/.github/workflows/deploy.yaml@refs/heads/master' && assertion.environment == 'production') || ",
        "(assertion.ref == 'refs/heads/master' && assertion.workflow_ref == 'a-novel/infra/.github/workflows/recovery.yaml@refs/heads/master' && assertion.environment == 'production'))",
      ])
    )
    error_message = "Only master workflows behind their environment may write, and only same-repository pull requests may plan."
  }

  assert {
    condition = alltrue([for provider in concat(values(google_iam_workload_identity_pool_provider.github), values(google_iam_workload_identity_pool_provider.visual_tests)) :
      strcontains(provider.attribute_condition, "assertion.repository_owner_id == '131281268'") &&
      provider.oidc[0].allowed_audiences == null
    ])
    error_message = "Every provider must pin the GitHub organization and Google's canonical audience."
  }

  assert {
    condition = alltrue([for binding in concat(values(google_project_iam_member.automation), values(google_project_iam_member.operator)) :
      !contains(["roles/owner", "roles/editor"], binding.role)
    ])
    error_message = "Automation and operators get scoped roles, never owner or editor."
  }
}
