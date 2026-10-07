# Workload project

This module provisions the project boundary for one independently operated service in one
environment. The API, jobs, and database that belong to that service will share this project. It also
prepares private storage custody, without creating deployment identities or activating a workflow.
The protected shared foundation owns this module; a service deployer must not own or apply it.

This is the compatibility composition for existing service-project callers. The
[project-shell module](../project-shell) now owns project provisioning under
`module.project`; [service-custody](../service-custody) owns retained storage
under `module.release`. The relative moves in `moved.tf` retain every caller's
project and storage resources, including `for_each` instances. Keep these moves
for existing states. Storage paths and schema-1 custody coordinates are unchanged;
obsolete release writers and their grants have been retired.

Production uses shared environment/trust-zone custody selected by `service_release_zones`.
This compatibility module is not selected by the current production configuration. A future
dedicated project requires an explicit exception review, not routine per-service onboarding.
Public-admin, staging and Kubernetes remain deferred.

The production caller is [foundation/service-projects.tf](../../environments/production/foundation/service-projects.tf).
Its empty `service_projects` map leaves the current deployment unchanged. See the
[onboarding boundary](../../docs/runbooks/provision-service-projects.md) before selecting a project.

## Ownership

The project, API, service-agent, logging and foundation IAM addresses below are
relative to `module.project`. Release and storage addresses are relative to `module.release`.

| Resource                                                                                           | Contract                                                                                                                                                                         |
| -------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `google_project.service`                                                                           | One explicit project ID, exactly one organization/folder parent, no default VPC, and persistent provider deletion prevention.                                                    |
| `google_project_service.api`                                                                       | Foundation owns the declared APIs, including Cloud Build and Storage; removing an entry leaves the API enabled for retained workloads and recovery.                              |
| `google_project_service_identity.agent` and `google_project_iam_member.service_agent`              | Create the Google-managed Run, Build, Scheduler, Workflows and Compute agents with their documented project roles.                                                               |
| `google_project_default_service_accounts.service`                                                  | Deprivilege default accounts after API activation. This is a creation-time repair; effective organization policies prevent future automatic grants and user-managed keys.        |
| `google_project_iam_member.foundation`, `.metadata`, and `google_project_iam_custom_role.metadata` | Project and service-account maintenance for the protected foundation identity. This is privileged IAM administration, not a service deployment role.                             |
| `google_project_iam_member.plan`                                                                   | Metadata assessment by the existing read-only plan identity. No payload access is declared.                                                                                      |
| `google_logging_project_bucket_config.default`                                                     | Thirty-day default log retention and provider deletion prevention.                                                                                                               |
| `google_storage_managed_folder.release` and `.release` IAM members                                 | Protected state and receipt folders in the existing management buckets. Only protected foundation writes; the plan identity reads the exact service state and operation records. |
| `google_storage_bucket_iam_member.plan_operation_reader`                                           | The plan identity reads only this service's operation, native-completion and rotation records; no receipt writes or bucket listing.                                              |

The caller owns Shared VPC attachment, exact-subnet access for Cloud Run/MIG agents and foundation, and budget scope. These grants
provide network attachment, not secret access or application invocation. The module creates no workloads, runtime
identities, keys, secret versions, registry, bucket, NAT, connector, or load balancer. Outputs contain
the project ID/number and a versioned `release` object with storage coordinates,
plus Google-managed IAM members for foundation wiring. Publish the custody
contract when activating a service; do not give a
consumer access to foundation's state.

The protected foundation account also receives repository, notification-channel and alert-policy administration
inside this project, for the inactive [service foundation](../../environments/service-foundation) and
[job monitoring](../service-job-access). Google's `roles/monitoring.alertPolicyEditor` grants policy
maintenance only to this protected account; routine release does not administer its own monitoring.
No application prerequisite is instantiated by this module.

API activation does not guarantee that a service agent already exists. The official `google-beta`
provider creates these identities before their role bindings; every other resource uses `google`.
Foundation pins both providers to the same version and Renovate groups their updates. The service
identity resource's delete operation is a no-op: it cannot remove a Google agent. Role bindings still
have their own lifecycle. Default Compute/Build execution accounts stay deprivileged. No primitive Owner or Editor grant is added here.

`google_project_iam_member.mig_agent` gives the project's Google APIs agent
(`PROJECT_NUMBER@cloudservices.gserviceaccount.com`) the documented Instance Group Manager Service
Agent role. It is distinct from the Compute Engine service agent and the database runtime account.
The service foundation grants exact host-account attachment; shared foundation grants exact-subnet use.
Check inherited/default Editor grants on the Google APIs agent explicitly: default execution-account
deprivileging does not establish that this separate agent has only its declared role.

## Protected provisioning authority

`../project-shell/foundation.tf` declares configuration permissions for the inactive service foundation. Only the
protected foundation account receives its control-plane role. Cloud Run job specifications/IAM, paused Scheduler and Workflows definitions, and artifact-bucket metadata/IAM stay
with that administrator. The role adds no direct job execution, rollout submission/approval, schedule
resume, Workflows execution, API service writes, object payload access or token minting.
Service and Workflows execution metadata reads support the existing protected
[completion finisher](../../docs/service-operations.md#finish-a-successful-operation). It reuses the
foundation identity's existing management-bucket custody and selected-project job reads; no native
mutation permission is added for completion repair.

The existing Viewer grant is supplemented with policy reads for the plan account. Resource metadata
and IAM-policy inspection are separate permissions; both are required for a complete refresh.

Resource owners grant `roles/iam.serviceAccountUser` on the exact identities they create. The service
foundation uses the management project's `infra-foundation` account and establishes these grants before
identity attachment. No project-wide Service Account User or Token Creator grant is added.

Foundation already administers project IAM and can change these grants. The narrow role is an explicit
operating contract, not protection against a compromised administrator. Protected inputs, reviewed
plans and live allowed/denied checks remain essential. The current empty service-project map creates
none of these grants; live provisioning and workload bootstrap need separate approval.

Compute Instance Admin is also declared for protected foundation, scoped to this service project,
to provision the optional idle database host, disk, templates and snapshots. It is not a configuration-only
role: it can manage instances. Routine release receives none of this authority. Restrict attachment to
the exact host identity and retain private saved plans/deletion protection. Google's MIG agent also
needs Shared VPC subnet use; see [Shared VPC provisioning](https://docs.cloud.google.com/vpc/docs/provisioning-shared-vpc#sa-as-spa).

References: [Run permissions](https://docs.cloud.google.com/run/docs/reference/iam/permissions),
[Scheduler permissions](https://docs.cloud.google.com/iam/docs/roles-permissions/cloudscheduler), and
[Storage permissions](https://docs.cloud.google.com/storage/docs/access-control/iam-permissions).

## Release boundary

This module now composes project provisioning with [service custody](../service-custody/README.md).
The former release identity and federation provider are retired.
Historical dedicated-project state remains under `services/<project-id>/release/`; evidence uses
the sibling `production/` folder. The current production deployment uses trust-zone coordinates.

The plan identity reads the exact state folder and operation/rotation evidence objects. It has no
write authority through these grants. Foundation remains the high-trust administrator; inherited
IAM must still be reviewed. Existing retention, versioning, soft delete and saved-plan expiration
remain in force. No state or backup content is removed with an automation identity.

## Validation and rollout

Persistent provider `PREVENT` policies protect the project,
log bucket and custody folders even when a caller removes a module instance. These apply-time
protections complement the saved-plan deletion gate.

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
