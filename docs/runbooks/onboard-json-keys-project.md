# JSON Keys project-shell onboarding

This is the approved first service project, not another disposable proof. It will initially hold
only synthetic rehearsal resources; creating its shell neither migrates production nor authorizes
those resources. Authentication stays in the existing workload project. The two September proof
projects have separate cleanup under [#190](https://github.com/a-novel/infra/issues/190).

The operator runs these steps after this onboarding PR merges. Agents may prepare code and run
the read-only trusted PR assessment, not these cloud or production-workflow commands. Keep sanitized
results under #190 and private plans/IAM inventories outside GitHub. Stop at each review boundary;
do not replay the completed [bootstrap apply](https://github.com/a-novel/infra/actions/runs/36781464657).

## 1. Confirm the scope and prerequisites

| Coordinate                     | Selected value                                                                    |
| ------------------------------ | --------------------------------------------------------------------------------- |
| New project                    | `a-novel-json-keys-prod`                                                          |
| Management / Shared VPC host   | `a-novel-management-prod` / `a-novel-production-prod`                             |
| Organization / billing account | `1031663934757` / `01BDFE-5B21E7-8393CB`                                          |
| Foundation principal           | `serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com` |
| Region / database zone         | `europe-west1` / `europe-west1-d`                                                 |
| New release environment        | `production-json-keys-release`                                                    |

As `geoffroy.vincent@agorastoryverse.com`, inspect management and host project metadata, their billing
links and effective organization policies. Both must be directly under the organization above and
use the stated billing account; stop if the actual parent is a folder or any coordinate differs.
Verify default-account deprivileging and service-account-key restrictions, as required by the
[shared onboarding contract](./provision-service-projects.md#first-activation-prerequisites).

```sh
gcloud projects describe a-novel-management-prod --account=geoffroy.vincent@agorastoryverse.com --format='yaml(projectId,projectNumber,lifecycleState,parent)'
gcloud projects describe a-novel-production-prod --account=geoffroy.vincent@agorastoryverse.com --format='yaml(projectId,projectNumber,lifecycleState,parent)'
gcloud billing projects describe a-novel-management-prod --account=geoffroy.vincent@agorastoryverse.com
gcloud billing projects describe a-novel-production-prod --account=geoffroy.vincent@agorastoryverse.com
gcloud projects list --account=geoffroy.vincent@agorastoryverse.com --filter='projectId=a-novel-json-keys-prod' --format='yaml(projectId,projectNumber,lifecycleState,parent)'
```

An empty listing means no matching project is visible to this account, not that the ID is globally
available. Do not create it manually. The existing module must own creation; on collision or partial
failure, inspect ownership and private state before any retry, import or ID change.

In the infra repository's **Settings → Environments**, create `production-json-keys-release` with
`kushuh` as a required reviewer, protected branches only and admin bypass disabled. Verify those
protections before the apply creates its federation provider. Install no release configuration and
enable no service workflow. Keep `SERVICE_FOUNDATIONS_ENABLED`, `SERVICE_JOB_BOOTSTRAP_ENABLED`
and `SERVICE_IMAGE_PROMOTION_ENABLED` unset, and repository-network selection `[]`.

## 2. Record and temporarily grant provisioning authority

The human IAM administrator first saves the existing organization and billing IAM policies privately.
Check the foundation principal's direct and inherited grants; do not duplicate existing authority or
later remove a binding that predates this operation. Stop for unexpected broad inherited access.
These are temporary additions, not changes to standing plan/maintenance roles:

```sh
onboarding_member=serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com
onboarding_expires="$(date -u -d '+2 hours' +%Y-%m-%dT%H:%M:%SZ)"
onboarding_condition="expression=request.time < timestamp('${onboarding_expires}'),title=JsonKeysProjectOnboarding"
printf '%s\n' "$onboarding_condition"
```

Save the exact printed condition with the private grant inventory before continuing. Expiry limits
authority but does not remove the binding. The following commands assume those grants were absent:

```sh
(set -eu
: "${onboarding_member:?}" "${onboarding_condition:?}"
gcloud organizations add-iam-policy-binding 1031663934757 --member="${onboarding_member:?}" --role=roles/resourcemanager.projectCreator --condition="${onboarding_condition:?}" --account=geoffroy.vincent@agorastoryverse.com
gcloud organizations add-iam-policy-binding 1031663934757 --member="${onboarding_member:?}" --role=roles/compute.xpnAdmin --condition="${onboarding_condition:?}" --account=geoffroy.vincent@agorastoryverse.com
gcloud billing accounts add-iam-policy-binding 01BDFE-5B21E7-8393CB --member="${onboarding_member:?}" --role=roles/billing.user --account=geoffroy.vincent@agorastoryverse.com
)
```

Shared VPC administration is at the common organization, not just the new project. Billing User is
not time-conditioned by this CLI command: explicitly remove the added binding on success **or
failure**. The current foundation already has project-IAM maintenance on the host; do not add
organization-wide Project IAM Admin or Owner. See Google's [Shared VPC prerequisites](https://docs.cloud.google.com/vpc/docs/provisioning-shared-vpc).

Do not use the generic `foundation-setup grant` / `finish` pair for this batch: it manages temporary
Owner on the legacy workload project, not Shared VPC administration or creator Owner on this new one.

## 3. Publish, plan, then separately review apply

Use clean, current infra `master`. Source `.envrc`, then use the existing
[`foundation-setup configure` publisher](./provision-service-projects.md#review-the-configuration).
Retain the previous publication's parent/adoption options and other inputs; this publisher replaces
the complete configuration in **both** protected environments, rather than merging remote settings.
Do not guess lost options or publish a map-only secret. The only intended input change is:

```json
{ "service_projects": { "json-keys": "a-novel-json-keys-prod" } }
```

Keep `pgbackrest_repository_services = []`; do not install service-root inputs. Wait for
`PASS foundation configure` for both environments. Then the human dispatches only the shared root:

```sh
gh workflow run foundation.yaml --repo a-novel/infra --ref master --field operation=plan --field root=foundation
```

Privately review the saved exact-commit plan. Expected changes are the selected project module,
keyless release federation, management-bucket service folders, Shared VPC host/attachment and
exact-subnet grants, the existing restricted HTTPS probe tag, and the budget's project scope.
Stop for any VM, disk, NAT, application, database, backup, schedule, secret payload, resource
replacement/deletion or unrelated legacy change. This shell adds no paid runtime; it is not a
quote or an automatic spending cap. Future host costs require their own review.

Only after that review, dispatch the same workflow with `operation=apply`, `root=foundation` and
the exact saved `plan_id` from the successful plan run, at the same master commit. Approve the
protected environment only for that operation. Preserve the workflow's private plan custody; no
local apply. On failure, reconcile accepted work and state before retrying, and remove temporary
grants without undoing or deleting partially created resources.

The PR's trusted assessment uses **current protected inputs**. It cannot validate this future
project-creation plan while those inputs still contain `service_projects = {}`.

## 4. Verify and remove temporary authority

After a successful apply, record the assigned project number and verify the complete
[first-activation checklist](./provision-service-projects.md#first-activation-prerequisites): parent,
billing, APIs, no default VPC/user-managed keys, effective policies and IAM, matching Google agent
roles, precise Shared VPC/subnet access and budget inclusion. Review the new project's IAM policy
privately; verify declared foundation maintenance grants before removing its automatic creator Owner.
Do not treat successful creation as proof of peer isolation or permission denials.

After verifying creator Owner exists and the declared replacement grants are present, remove it:

```sh
gcloud projects remove-iam-policy-binding a-novel-json-keys-prod --member=serviceAccount:infra-foundation@a-novel-management-prod.iam.gserviceaccount.com --role=roles/owner --condition=None --account=geoffroy.vincent@agorastoryverse.com
```

Separately remove the parent/billing additions recorded for this operation, including after a failed
apply that never created the project. Recover the exact `onboarding_condition` from the private
inventory if the terminal session changed; do not generate a new expiry. The batch below assumes
all three additions succeeded; after a partial grant, remove only the bindings actually added:

```sh
(set -eu
: "${onboarding_member:?}" "${onboarding_condition:?}"
gcloud organizations remove-iam-policy-binding 1031663934757 --member="${onboarding_member:?}" --role=roles/resourcemanager.projectCreator --condition="${onboarding_condition:?}" --account=geoffroy.vincent@agorastoryverse.com
gcloud organizations remove-iam-policy-binding 1031663934757 --member="${onboarding_member:?}" --role=roles/compute.xpnAdmin --condition="${onboarding_condition:?}" --account=geoffroy.vincent@agorastoryverse.com
gcloud billing accounts remove-iam-policy-binding 01BDFE-5B21E7-8393CB --member="${onboarding_member:?}" --role=roles/billing.user --account=geoffroy.vincent@agorastoryverse.com
)
```

Fetch fresh project, organization and billing policies; verify those added bindings are absent and
standing grants remain. Re-run the shared **plan only** with the grants removed: require zero
changes. If that fails, inspect the missing permission rather than restoring Owner. Store successful
sanitized checks under #190. Keep the project and attachment deletion guards enabled.

Stop here. Native repository networking, service-root provisioning, credentials, image publication,
host start, backups and schedules each retain their separate approval boundary. Production traffic,
logical backups and snapshots are unchanged.
