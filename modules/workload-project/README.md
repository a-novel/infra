# Workload project

This module provisions the project boundary for one independently operated service in one
environment. The API, jobs, and database that belong to that service will share this project.
The protected shared foundation owns this module; a service deployer must not own or apply it.

The production caller is [foundation/service-projects.tf](../../environments/production/foundation/service-projects.tf).
Its empty `service_projects` map leaves the current deployment unchanged. See the
[onboarding boundary](../../docs/runbooks/provision-service-projects.md) before selecting a project.

## Ownership

| Resource                                                                                           | Contract                                                                                                                                                                  |
| -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `google_project.service`                                                                           | One explicit project ID, exactly one organization/folder parent, no default VPC, provider deletion prevention and `prevent_destroy`.                                      |
| `google_project_service.api`                                                                       | Foundation owns the twelve declared APIs; removing an entry leaves the API enabled for retained workloads and recovery.                                                   |
| `google_project_default_service_accounts.service`                                                  | Deprivilege default accounts after API activation. This is a creation-time repair; effective organization policies prevent future automatic grants and user-managed keys. |
| `google_project_iam_member.foundation`, `.metadata`, and `google_project_iam_custom_role.metadata` | Project-shell maintenance for the protected foundation identity. This is privileged IAM administration, not a service deployment role.                                    |
| `google_project_iam_member.plan`                                                                   | Metadata assessment by the existing read-only plan identity. No payload access is declared.                                                                               |
| `google_logging_project_bucket_config.default`                                                     | Thirty-day default log retention and provider deletion prevention.                                                                                                        |

The caller owns Shared VPC attachment and budget scope. Attachment grants no subnet use, secret
access, service invocation, or deployment permission. The module creates no workloads, runtime
identities, keys, secret versions, registry, state bucket, NAT, connector, or load balancer.
Outputs contain only the project ID and number.

## Validation and rollout

The foundation's native mocked tests exercise this module and its caller through the existing
`validate-opentofu` check. No cloud credentials are needed. Mocked results establish configuration
contracts; they do not prove live IAM propagation, network connectivity, or migration safety.

Project IDs are immutable ownership coordinates. Renaming a service key or replacing a project
requires an explicit state-transfer/decommission review. Deletion guards and the existing saved-plan
gate must remain active; a deletion label alone does not override them. Project creation can grant
the creator Owner, which the human operator must remove after verifying the maintenance grants.

Provider references: [project](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project),
[APIs](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project_service),
[default accounts](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project_default_service_accounts),
[project IAM](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project_iam),
[custom role](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/google_project_iam_custom_role),
and [log bucket](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/logging_project_bucket_config).
Product references: [project creation](https://cloud.google.com/resource-manager/docs/creating-managing-projects),
[Shared VPC](https://cloud.google.com/vpc/docs/shared-vpc),
[service-account security](https://cloud.google.com/iam/docs/best-practices-for-managing-service-account-keys),
and [log retention](https://cloud.google.com/logging/docs/buckets).
