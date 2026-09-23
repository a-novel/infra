# Workload project

This module provisions the project boundary for one independently operated service in one
environment. The API, jobs, and database that belong to that service will share this project. It also
prepares the service's release identity and private storage boundary, without activating a workflow.
The protected shared foundation owns this module; a service deployer must not own or apply it.

The production caller is [foundation/service-projects.tf](../../environments/production/foundation/service-projects.tf).
Its empty `service_projects` map leaves the current deployment unchanged. See the
[onboarding boundary](../../docs/runbooks/provision-service-projects.md) before selecting a project.

## Ownership

| Resource                                                                                                                                           | Contract                                                                                                                                                                                               |
| -------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `google_project.service`                                                                                                                           | One explicit project ID, exactly one organization/folder parent, no default VPC, provider deletion prevention and `prevent_destroy`.                                                                   |
| `google_project_service.api`                                                                                                                       | Foundation owns the declared APIs, including Cloud Build, Cloud Deploy and Storage; removing an entry leaves the API enabled for retained workloads and recovery.                                      |
| `google_project_service_identity.agent` and `google_project_iam_member.service_agent`                                                              | Create the Google-managed Run, Build, Deploy and Scheduler agents and bind each documented service-agent role in its own project.                                                                      |
| `google_project_default_service_accounts.service`                                                                                                  | Deprivilege default accounts after API activation. This is a creation-time repair; effective organization policies prevent future automatic grants and user-managed keys.                              |
| `google_project_iam_member.foundation`, `.metadata`, and `google_project_iam_custom_role.metadata`                                                 | Project and service-account maintenance for the protected foundation identity. This is privileged IAM administration, not a service deployment role.                                                   |
| `google_project_iam_member.plan`                                                                                                                   | Metadata assessment by the existing read-only plan identity. No payload access is declared.                                                                                                            |
| `google_logging_project_bucket_config.default`                                                                                                     | Thirty-day default log retention and provider deletion prevention.                                                                                                                                     |
| `google_service_account.release`, `google_iam_workload_identity_pool_provider.release`, and `google_service_account_iam_member.release_federation` | A project-local `infra-release` account trusts only its service environment and the exact master release workflow, via a provider in the bootstrap-owned pool. No key or outbound impersonation grant. |
| `google_storage_managed_folder.release` and `.release` IAM members                                                                                 | Protected state and receipt folders in the existing management buckets. The matching release account can write state and create/read receipts, but cannot replace or delete receipts.                  |
| `google_storage_bucket_iam_member.release_metadata` and `google_storage_managed_folder_iam_member.plan`                                            | Release reads state-bucket metadata only; the existing plan identity gains read-only access to the selected service's state folder. Neither grant permits bucket administration.                       |

The caller owns Shared VPC attachment, Cloud Run agent subnet access, and budget scope. These grants
provide network attachment, not secret access or application invocation. The module creates no workloads, runtime
identities, keys, secret versions, registry, bucket, NAT, connector, or load balancer. Outputs contain
the project ID/number and a versioned `release` object with only the identity, provider, environment,
and storage coordinates, plus Google-managed IAM members for foundation wiring. Publish the release
contract when activating a service; do not give a
consumer access to foundation's state.

The protected foundation account also receives repository, notification-channel and alert-policy administration
inside this project, for the separately composed [application prerequisites](../service-foundation) and
[job monitoring](../service-job-access). Google's `roles/monitoring.alertPolicyEditor` grants policy
maintenance only to this protected account; routine release does not administer its own monitoring.
No application prerequisite is instantiated by this module.

API activation does not guarantee that a service agent already exists. The official `google-beta`
provider creates these identities before their role bindings; every other resource uses `google`.
Foundation pins both providers to the same version and Renovate groups their updates. The service
identity resource's delete operation is a no-op: it cannot remove a Google agent. Role bindings still
have their own lifecycle. Default Compute/Build execution accounts stay deprivileged; the rollout
module selects dedicated execution identities. No primitive Owner or Editor grant is added here.

## Release boundary

The provider `r-<project-id>` trusts immutable repository/owner IDs, `refs/heads/master`, the exact
`release.yaml` workflow, and `<environment>-<service>-release`. Its constant `service_release`
attribute selects only its matching account. GitHub's environment name alone is not approval:
reviewers, branch restrictions, and no admin bypass must be configured before activation. The
current `production-release` workflow cannot use this identity unchanged.

State lives under `services/<project-id>/release/` and receipts under
`services/<project-id>/production/`. These are siblings of the legacy `release/`, `production/`,
and `recovery/` folders: managed-folder IAM is additive, so a child of a legacy folder would inherit
its writers. The release account receives no project role, peer storage, secret access, or runtime
permission. Foundation remains the explicit high-trust administrator; inherited project/organization
grants must also be checked during live verification.

Existing bucket protections and lifecycle policies still apply. Empty folders and keyless identities
add no paid runtime; future object storage/operations are billable. Saved-plan location and expiry,
service-specific runtime grants, state handoff, and interrupted-rollout handling belong to the
separate service-lifecycle rollout, not this boundary module.

## Validation and rollout

The foundation's native mocked tests exercise this module and its caller through the existing
`validate-opentofu` check. No cloud credentials are needed. Mocked results establish configuration
contracts; they do not prove live IAM propagation, network connectivity, or migration safety.

Project IDs are immutable ownership coordinates. Renaming a service key or replacing a project
requires an explicit state-transfer/decommission review. Deletion guards and the existing saved-plan
gate must remain active; a deletion label alone does not override them. Project creation can grant
the creator Owner, which the human operator must remove after verifying the maintenance grants.

Provider references: [project](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project),
[service identity](https://registry.terraform.io/providers/hashicorp/google-beta/8.2.0/docs/resources/project_service_identity),
[APIs](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project_service),
[default accounts](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project_default_service_accounts),
[project IAM](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project_iam),
[custom role](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project_iam_custom_role),
and [log bucket](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/logging_project_bucket_config).
Product references: [project creation](https://cloud.google.com/resource-manager/docs/creating-managing-projects),
[Shared VPC](https://cloud.google.com/vpc/docs/shared-vpc),
[service agents](https://docs.cloud.google.com/iam/docs/service-agents),
[service-account security](https://cloud.google.com/iam/docs/best-practices-for-managing-service-account-keys),
[log retention](https://cloud.google.com/logging/docs/buckets),
[managed-folder inheritance](https://cloud.google.com/storage/docs/managed-folders),
[deployment federation](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines),
and [GCS backend locking](https://opentofu.org/docs/language/settings/backends/gcs/).
