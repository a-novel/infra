# Release boundary

A release boundary gives one service its own keyless identity, state and receipt folders.
Shared projects use one boundary per service, environment and trust zone. The protected
foundation owns the boundary; it grants no project deployment, runtime, secret, network
or job-execution permission.

## Configuration

The production foundation selects boundaries through `service_release_zones`, default `{}`.
It resolves `private` to the existing workload project and `public` to the optional public shell.
The [onboarding runbook](../../docs/runbooks/provision-service-projects.md#shared-project-release-boundaries)
describes validation and activation prerequisites. Keep the selection empty until zone-aware
workflow registration, single-writer state handoff and runtime permissions are reviewed.

`workload-project` also uses this module with `zone = null` for dedicated-project compatibility.
That profile preserves the existing identity, grants and schema-1 output; its relative moves
retain existing state ownership. `retirement` is available only for that compatibility profile.

## Identity and storage contract

| Coordinate         | Shared-zone contract                                                                                                                                                                          |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Service account    | `infra-<service>-<zone>` in the selected project; persistent deletion prevention.                                                                                                             |
| GitHub environment | `<environment>-<service>-<zone>-release`; configure required reviewers, protected branches and no admin bypass before creating federation.                                                    |
| Provider           | Management's existing `github-actions` pool; stable `r-` plus 28 hex characters of the environment/project/service/zone scope hash.                                                           |
| Federation         | Immutable repository and owner IDs, master, the exact release workflow and environment; a constant scope attribute selects the matching account.                                              |
| State              | `workloads/<environment>/<zone>/<project>/<service>/release/` in the existing state bucket. Only this release account writes; the plan identity reads.                                        |
| Receipts           | The sibling `production/` folder in the existing receipt bucket. Release can create/read, but not overwrite/delete. Planning reads only exact operation, native-success and rotation records. |
| Output             | Schema 2 includes service, zone, project and identity/storage coordinates. Existing schema-1 consumers must not interpret it as runtime enrollment.                                           |

Managed-folder IAM is [additive](https://docs.cloud.google.com/storage/docs/managed-folders).
The new `workloads/` namespace is a sibling of existing service and legacy namespaces, not a
child inheriting their writers. Ancestor IAM still applies: verify effective own-folder access
and peer/legacy denials before activation. Foundation remains a high-trust administrator.

The release identity can read state-bucket metadata but receives no bucket administration or
outbound impersonation grant. Wrong repository/ref/workflow/environment federation and peer-zone
access must fail in live checks; mocked tests establish only the configuration contract.

No bucket or paid runtime is created by this module. Future storage and operations are billable.
Select saved-plan locations and verify their expiration policy before workflow activation;
the existing `services/` plan lifecycle does not cover `workloads/`. No state or retained
receipt is copied, removed or adopted by selecting a boundary.
