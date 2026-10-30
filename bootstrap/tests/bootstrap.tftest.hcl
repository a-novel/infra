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

mock_provider "google-beta" {
  mock_resource "google_project_service_identity" {
    defaults = { member = "serviceAccount:mock-agent@gcp-sa-workflows.iam.gserviceaccount.com" }
  }
}

run "protects_state_and_backups" {
  command = plan

  assert {
    condition = alltrue([for bucket in concat([google_storage_bucket.state], values(google_storage_bucket.pgbackrest), values(google_storage_bucket.barman)) :
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
    condition = alltrue([for bucket in concat(values(google_storage_bucket.pgbackrest), values(google_storage_bucket.barman)) :
      bucket.versioning[0].enabled && tonumber(bucket.retention_policy[0].retention_period) == 604800 &&
      alltrue([for rule in bucket.lifecycle_rule : alltrue([for condition in rule.condition : condition.age == null || condition.age == 0])])
    ])
    error_message = "Backup repositories keep a week of retention and are never pruned by age; pgBackRest and Barman own expiry."
  }

  assert {
    condition = alltrue([for bucket in google_storage_bucket.pgbackrest :
      length(bucket.lifecycle_rule) == 0 || bucket.soft_delete_policy[0].retention_duration_seconds == 0
    ])
    error_message = "A backup bucket that deletes replaced objects must keep no soft-deleted copy of them."
  }

  assert {
    condition = alltrue([for name, secret in google_secret_manager_secret.application :
      secret.deletion_protection && secret.version_destroy_ttl == "2592000s" if !contains(local.retiring_secrets, name)
    ])
    error_message = "Secrets must refuse deletion and keep destroyed versions recoverable for 30 days."
  }

  assert {
    condition = (
      google_secret_manager_secret_iam_member.sentry_token["plan"].secret_id == "production-sentry-plan-token" &&
      toset(keys(google_secret_manager_secret_iam_member.sentry_token)) == toset(["plan", "foundation"])
    )
    error_message = "The plan identity runs pull-request code, so it may read only the read-only Sentry token."
  }

  assert {
    condition = (
      google_secret_manager_secret_iam_member.grafana_token["plan"].secret_id == "production-grafana-plan-token" &&
      toset(keys(google_secret_manager_secret_iam_member.grafana_token)) == toset(["plan", "foundation"]) &&
      google_secret_manager_secret_iam_member.grafana_cloud_token["plan"].secret_id == "production-grafana-cloud-plan-token" &&
      toset(keys(google_secret_manager_secret_iam_member.grafana_cloud_token)) == toset(["plan", "foundation"])
    )
    error_message = "The plan identity runs pull-request code, so it may read only the read-only Grafana tokens."
  }

  assert {
    condition = (
      toset([for key, grant in google_secret_manager_secret_iam_member.github_root : grant.secret_id if startswith(key, "plan:")]) ==
      toset(["production-github-plan-key-a-novel", "production-github-plan-key-a-novel-kit"]) &&
      toset([for key, grant in google_secret_manager_secret_iam_member.github_root : grant.secret_id if startswith(key, "drift:")]) ==
      toset(["production-github-deploy-key-a-novel", "production-github-deploy-key-a-novel-kit"]) &&
      alltrue([for key, grant in google_secret_manager_secret_iam_member.github_root : startswith(key, "github:") if strcontains(grant.secret_id, "-governance-")]) &&
      !anytrue([for key in keys(google_secret_manager_secret_iam_member.github_root) : startswith(key, "foundation:")])
    )
    error_message = "The plan identity runs pull-request code, so it may read only the Plan App keys; the drift identity reads only the Deploy App keys; only the GitHub root's deploys read the governance secrets, and Google Cloud's deploy identity reads none of them."
  }

  assert {
    condition     = toset(keys(google_secret_manager_secret_iam_member.github_root_metadata)) == toset([for key in keys(google_secret_manager_secret_iam_member.github_root) : key if !startswith(key, "plan:")])
    error_message = "The GitHub root's deploy and drift identities need to read each key's version metadata, which the plan identity's project role already grants."
  }

  assert {
    condition     = endswith(google_storage_bucket_iam_member.github_state.condition[0].expression, "/objects/github/\")")
    error_message = "The GitHub root's deploys may write their own state alone."
  }
}

run "isolates_each_database_backup" {
  command = plan

  assert {
    condition = alltrue([for service, grant in google_storage_bucket_iam_member.barman_writer :
      grant.bucket == google_storage_bucket.barman[service].name && endswith(grant.member, "/subject/ns/${service}/sa/database")
    ])
    error_message = "Each Barman bucket must be written only by its own service's database service account."
  }

  assert {
    condition     = length(setsubtract(["storage.buckets.get", "storage.multipartUploads.create"], google_project_iam_custom_role.barman_writer.permissions)) == 0
    error_message = "Barman must read its bucket, which it checks before archiving, and upload in parts, as base backups do."
  }

  assert {
    condition     = alltrue([for permission in google_project_iam_custom_role.barman_reader.permissions : contains(["storage.buckets.get", "storage.objects.get", "storage.objects.list"], permission)])
    error_message = "A recovery drill may only read the backups it restores."
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
        "(assertion.ref == 'refs/heads/master' && assertion.workflow_ref == 'a-novel/infra/.github/workflows/recovery.yaml@refs/heads/master' && assertion.environment == 'production') || ",
        "(assertion.ref == 'refs/heads/master' && assertion.workflow_ref == 'a-novel/infra/.github/workflows/roll-database.yaml@refs/heads/master' && assertion.environment == 'production'))",
      ]) &&
      google_iam_workload_identity_pool_provider.github["downtime"].attribute_condition == join("", [
        "assertion.repository_owner_id == '131281268' && assertion.repository_id == '1344262359' && (",
        "(assertion.ref == 'refs/heads/master' && assertion.workflow_ref == 'a-novel/infra/.github/workflows/downtime.yaml@refs/heads/master'))",
      ]) &&
      google_iam_workload_identity_pool_provider.github["health"].attribute_condition == join("", [
        "assertion.repository_owner_id == '131281268' && assertion.repository_id == '1344262359' && (",
        "(assertion.ref == 'refs/heads/master' && assertion.workflow_ref == 'a-novel/infra/.github/workflows/drift.yaml@refs/heads/master'))",
      ]) &&
      google_iam_workload_identity_pool_provider.github["github"].attribute_condition == join("", [
        "assertion.repository_owner_id == '131281268' && assertion.repository_id == '1344262359' && (",
        "(assertion.ref == 'refs/heads/master' && assertion.workflow_ref == 'a-novel/infra/.github/workflows/deploy.yaml@refs/heads/master' && assertion.environment == 'github') || ",
        "(assertion.ref == 'refs/heads/master' && assertion.workflow_ref == 'a-novel/infra/.github/workflows/sweep.yaml@refs/heads/master' && assertion.environment == 'github'))",
      ]) &&
      google_iam_workload_identity_pool_provider.github["drift"].attribute_condition == join("", [
        "assertion.repository_owner_id == '131281268' && assertion.repository_id == '1344262359' && (",
        "(assertion.ref == 'refs/heads/master' && assertion.workflow_ref == 'a-novel/infra/.github/workflows/drift.yaml@refs/heads/master'))",
      ])
    )
    error_message = "Only master workflows behind their environment may write, call Authentication or read the GitHub Deploy App keys, and only same-repository pull requests may plan."
  }

  assert {
    condition = (
      google_iam_workload_identity_pool_provider.visual_tests["studio-ci"].attribute_condition == join("", [
        "assertion.repository_owner_id == '131281268' && assertion.repository_id == '1338436652' && ",
        "assertion.repository == 'a-novel/platform-studio' && ",
        "(assertion.workflow_ref == 'a-novel/platform-studio/.github/workflows/main.yaml@' + assertion.ref) && (",
        "(assertion.ref.startsWith('refs/heads/') && assertion.event_name in ['push', 'merge_group']) || ",
        "(assertion.event_name == 'pull_request' && assertion.base_ref == 'master' && assertion.ref.startsWith('refs/pull/')))",
      ]) &&
      google_iam_workload_identity_pool_provider.visual_tests["studio-maintenance"].attribute_condition == join("", [
        "assertion.repository_owner_id == '131281268' && assertion.repository_id == '1338436652' && ",
        "assertion.repository == 'a-novel/platform-studio' && ",
        "((assertion.workflow_ref == 'a-novel/platform-studio/.github/workflows/main.yaml@refs/heads/master' && assertion.event_name == 'push') || ",
        "(assertion.workflow_ref == 'a-novel/platform-studio/.github/workflows/visual-tests.yaml@refs/heads/master' && ",
        "assertion.event_name in ['workflow_run', 'pull_request_target', 'delete', 'schedule'])) && ",
        "assertion.ref == 'refs/heads/master'",
      ])
    )
    error_message = "Visual-test CI runs on main.yaml from a branch, the merge queue or a pull request into master; only master may stage references."
  }

  assert {
    condition = alltrue([for workflow in [google_workflows_workflow.downtime_announcements, google_workflows_workflow.github_dispatch] :
      workflow.call_log_level == "LOG_NONE" && workflow.execution_history_level == "EXECUTION_HISTORY_BASIC"
    ])
    error_message = "Call logs and detailed history would record the secrets the workflows read: the Discord webhook and the GitHub dispatch tokens."
  }

  # Only uikit's visual tests trust a repository outside the a-novel organization.
  assert {
    condition = alltrue([for provider in concat(values(google_iam_workload_identity_pool_provider.github), values(google_iam_workload_identity_pool_provider.visual_tests)) :
      strcontains(provider.attribute_condition, "assertion.repository_owner_id == '${strcontains(provider.attribute_condition, "assertion.repository == 'a-novel-kit/uikit'") ? "187672320" : "131281268"}'") &&
      provider.oidc[0].allowed_audiences == null
    ])
    error_message = "Every provider must pin its repository's GitHub organization and Google's canonical audience."
  }

  # Google rejects a longer provider display name only at apply time.
  assert {
    condition = alltrue([for provider in concat(values(google_iam_workload_identity_pool_provider.github), values(google_iam_workload_identity_pool_provider.visual_tests)) :
      length(provider.display_name) <= 32
    ])
    error_message = "Workload identity provider display names are limited to 32 characters."
  }

  assert {
    condition = alltrue(flatten([for repositories in values(jsondecode(google_workflows_workflow.github_dispatch.user_env_vars.SCHEDULED)) :
      [for repository in repositories : contains(keys(jsondecode(google_workflows_workflow.github_dispatch.user_env_vars.TOKEN_VERSIONS)), split("/", repository)[0])]
    ]))
    error_message = "Every repository a schedule lists needs its org's dispatch token."
  }

  # Google rejects a reserved environment variable name only at apply time.
  assert {
    condition = alltrue(flatten([for workflow in [google_workflows_workflow.downtime_announcements, google_workflows_workflow.github_dispatch] :
      [for name in keys(workflow.user_env_vars) : !startswith(name, "GOOGLE") && !startswith(name, "WORKFLOWS")]
    ]))
    error_message = "Workflows environment variable names cannot begin with GOOGLE or WORKFLOWS."
  }

  assert {
    condition = alltrue([for binding in concat(values(google_project_iam_member.automation), values(google_project_iam_member.operator)) :
      !contains(["roles/owner", "roles/editor"], binding.role)
    ])
    error_message = "Automation and operators get scoped roles, never owner or editor."
  }

  assert {
    condition     = contains(keys(google_project_iam_member.automation), "foundation:roles/storage.admin")
    error_message = "The deploy identity creates management buckets, which takes a project-level storage role."
  }
}
