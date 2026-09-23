# Service-project onboarding boundary

Service projects are opt-in project shells with separate release identities and private storage
folders. Production still runs in the existing workload project, under the existing release identity.
Keep `INFRA_SERVICE_PROJECTS='{}'` in `.envrc` until a separately reviewed onboarding change supplies
the exact project IDs, temporary provisioning permissions, verification, and access-removal
commands. Merging the project module is not authorization to create a project or move a workload.

## Review the configuration

The reviewed `.envrc` declares a JSON object mapping service names to project IDs. For example, these
synthetic values select two project shells:

```sh
export INFRA_SERVICE_PROJECTS='{"json-keys":"agora-json-keys-test","authentication":"agora-authentication-test"}'
```

Use one entry per independently operated service and environment, not per image, job, or revision.
Project IDs must differ from each other, management, and the existing workload project. A production
service project requires the same organization/folder parent as the foundation. OpenTofu validates
these constraints before apply.

After the selection is reviewed and configuration publication is authorized, run from clean, current
`master` as the human operator:

```sh
. ./.envrc
go run ./cmd/infra foundation-setup configure
```

Reuse the existing project-parent and adoption options from the
[workload foundation setup](./provision-workload-foundation.md#2-publish-the-protected-configuration).
This publishes the complete source configuration to both protected environments. An explicit
`--service-projects '{"json-keys":"agora-json-keys-test"}'` overrides the environment for that call;
keep the durable selection in `.envrc` so later publications preserve it. An unset or malformed
selection fails before any external command. Use `{}` explicitly when no service projects exist.

Continue only after `PASS foundation configure`. The two environment writes are separate operations;
if either fails, resolve the failure and rerun the same reviewed configuration before any workflow.
Publication changes no cloud resource. The existing protected foundation plan/apply path consumes
the complete private configuration with its existing custody and serialization.

Recovery retains the source project map only to reject a production service project as a replacement
target. Its compiler always writes `service_projects = {}` into the disposable foundation inputs;
the root also rejects a nonempty map in recovery mode. Older source configurations without the map
remain supported.

## What the plan will own

- The [project module](../../modules/workload-project/README.md) creates protected project shells,
  enables APIs, deprivileges default accounts, grants foundation maintenance and plan inspection,
  creates the Google-managed Run/Build/Deploy/Scheduler/Compute agents with their documented roles, and bounds default
  logs. Each service also gets a keyless release account, an exact federation
  provider, and managed folders for its state and receipts in the management buckets.
- Foundation enables the existing workload project as a Shared VPC host and attaches each shell.
  It owns the VPC, subnet, routes, firewall rules, and DNS. Both host and attachment have deletion
  guards. The Cloud Run agent receives host Network Viewer; Cloud Run, the Google APIs MIG agent
  and protected foundation receive Network User on the exact production subnet. The MIG agent gets
  its documented instance-management role only in its service project. The secret-free rollout probe tag joins the existing restricted Google HTTPS
  allow; it gains no database egress.
- The existing production budget includes the new project numbers. Its amount, thresholds, and
  notification channels remain unchanged. No paid runtime or network appliance is provisioned.

An attachment is not a network-security proof. Effective subnet permissions, firewall and
egress policy, Cloud Run internal routing, and application authentication must be verified before
deploying a service. Current deployers receive no new-project grants. New release accounts can write
only their own state and create/read their own receipts; they cannot yet deploy a workload. Legacy
state, receipts, secrets, and backups retain their existing owners and paths.

## First activation prerequisites

Before the first apply creates federation, create each exact `<environment>-<service>-release`
GitHub environment with required reviewers, protected-branch restriction, and admin bypass disabled.
An environment name in a token does not prove those protections exist.

The onboarding PR must record the exact operator commands and successful sanitized results for:

1. Project Creator and billing-link authority for the protected foundation identity, plus temporary
   Shared VPC administration at the appropriate parent. All projects must belong to the same
   organization. Inherited default-account and service-account-key policies must be enforced.
2. Publishing the reviewed selection with the command above. Do not replace the complete protected
   configuration with a map-only document or reuse the synthetic project IDs.
3. The existing separate reviewed plan and apply runs. Inspect project creation, API/IAM changes,
   Shared VPC attachment, release identity/folder grants, and budget scope; stop for workload changes
   or legacy resource replacement.
4. Verifying exact project parents/billing, no default VPC, enabled APIs, zero user-managed keys,
   effective organization policies, deprivileged default accounts, host attachment, and budget scope.
   Verify all declared Google agents have their matching project role, only the Cloud Run agent has
   host Network Viewer, and the declared Cloud Run/MIG/foundation principals have exact-subnet use.
   Check no host-wide Network User or primitive role is inherited, including Editor on the Google APIs
   MIG agent (separate from default execution-account deprivileging). Test probe
   HTTPS reachability and denied database access once the separately approved probe exists.
5. Removing temporary Owner/project-creation/billing/Shared VPC grants and verifying that the
   standing maintenance identity can still produce a zero-change plan.

Before a service workflow uses the new identity, its separate rollout must also:

- Recheck the environment protections and bind the reviewed workflow to the published `release`
  coordinates; never let an arbitrary workflow input choose a privileged identity.
- Verify both permitted operations and denials: own-state read/write/locking, own-receipt
  create/read, denied receipt overwrite/delete, and denied peer/legacy state, secret, and runtime
  access. Review inherited IAM too. Check that a wrong repository, ref, workflow, or environment
  cannot federate; mocked tests cannot establish these live results.
- Select saved-plan storage/expiry and publish only the versioned coordinates, not foundation
  state. Preserve private plan custody, exact-commit approval, and a single writer during the
  transfer; a separate folder is not itself a migration or rollback plan.

Use the existing foundation workflow; do not apply this module from a local terminal. After an
interruption, inspect actual project ownership and the saved state before retrying. Do not import,
delete, or change a globally unique project ID to work around a failed creation. Keep the project
and attachment guards in place during reconciliation.

Moving the first service requires a separate ownership-transfer plan covering its identities, state,
registry, runtime, database, secrets, backups, retained receipts, and health/rollback evidence. The
shared foundation remains privileged, and release concurrency stays serialized until those service
boundaries have been verified.

The inactive [service foundation root](../../environments/service-foundation) composes the runtime,
rollout control plane and application-job access using those published project coordinates. Its
bootstrap sequence keeps prerequisites separate from activation. Its protected planning path below
is disabled by default; the service release root still has no live workflow caller. This runbook does
not authorize provisioning either root.

Its optional [database host](../../environments/service-foundation#optional-idle-database-host) also
requires a separately approved provisioning step: dedicated runtime/secret access, idle boot evidence,
exact network rules, backups and safe maintenance ownership. Compute Instance Admin belongs only to
protected foundation in that project, not routine release. Keeping the host idle does not eliminate its
VM/disk/snapshot cost; leaving `database = null` creates none of those resources. No existing production
resource or state address is moved by this definition.

## Protected service-foundation plans

This code path reuses the existing foundation environment, identity, global execution lock and
saved-plan policy. Keep `SERVICE_FOUNDATIONS_ENABLED` unset until the separately reviewed onboarding
PR authorizes live provisioning. That activation must also extend trusted deletion assessment and
scheduled drift to initialized service roots; current fleet assessment still covers the legacy roots.
No service configuration or activation flag is installed by merging this code.

The operator supplies `SERVICE_FOUNDATIONS_JSON` in `production-foundation`: an object keyed by
`json-keys` or `authentication`, containing that root's native tfvars. For example, this is a synthetic
runtime-only entry; use reviewed real coordinates before publication:

```json
{
  "json-keys": {
    "service": "json-keys",
    "project_id": "agora-json-keys-test",
    "management_project_id": "agora-management-test",
    "state_bucket": "agora-management-test-123-tofu-state",
    "region": "europe-west1",
    "operations_alert_email": "operations@example.invalid"
  }
}
```

Keep payloads out of this document. Optional database/rollout/job-access inputs follow the
[root's bootstrap sequence](../../environments/service-foundation#bootstrap-sequence). The selected
service/project must match `FOUNDATION_TFVARS_JSON.service_projects`; management and region must
match the same protected document. Management and bucket must also match the published repository
coordinates. Missing or mismatched inputs stop before authentication and are checked again before
backend initialization. Root HCL owns resource validation; this selection does not prove cloud
prerequisites or effective IAM.

After authorization, publish the reviewed private document from outside the checkout, preserving
existing service entries:

```sh
gh secret set SERVICE_FOUNDATIONS_JSON --repo a-novel/infra --env production-foundation <"${SERVICE_FOUNDATIONS_FILE:?}"
```

After the activation prerequisites are met and the enable flag is explicitly approved, use clean,
current `master`:

```sh
SERVICE_FOUNDATION_PLAN_ID="$(go run ./cmd/infra foundation plan service-foundation json-keys)"
```

Inspect the sanitized plan, approve required deletion on its exact merged PR, and apply the selected
unexpired plan in a separate protected run:

```sh
go run ./cmd/infra foundation apply service-foundation json-keys "${SERVICE_FOUNDATION_PLAN_ID:?}"
```

Replace `json-keys` with `authentication` for that service. Do not pass project IDs, backend overrides
or alternate workspaces. The root uses a fresh backend working directory and native GCS locking.
State is `foundation/services/PROJECT/default.tfstate`; converged configuration is recorded under
`foundation/services/PROJECT/config/`. Opaque plans remain under the existing 24-hour expiry prefix,
`foundation/plans/services/PROJECT/COMMIT/PLAN-ID/`, with distinct root/project metadata and checksum.
Other services and recovery cannot reuse that scope. No storage IAM changes are introduced.

Apply consumes the exact saved plan before mutation, then requires convergence before publishing
configuration. If it fails or is interrupted, inspect the actual resources and state before creating
a fresh plan. Never replay a consumed plan or assume a failed run made no changes. This path does
not transfer an existing resource owner, start PostgreSQL, run a migration or activate Cloud Deploy.
Consumers still need approved versioned output publication; do not grant them foundation-state access.

## Service scheduling activation

The inactive [job-access module](../../modules/service-job-access) keeps JSON Keys rotation paused.
There is no command to activate it in this runbook yet. Its first protected apply requires the
existing rotation job, the declared Scheduler service agent/role, Scheduler administration and
`actAs` on the fresh scheduling identity. Verify that identity has no inherited invocation grants
before creation; its exact-job grant is applied only after the provider has paused the schedule.
Those configuration and attachment grants are declared by the project and job-access modules.
Verify their effective permissions and propagation during approved provisioning. Schedule resume
and dispatch remain outside the protected executor's control-plane role.

The separate activation PR must supply a one-writer state handoff and human-run verification of:

- The exact paused schedule, hourly UTC cadence, empty OAuth request and zero dispatch retries.
- Own-rotation invocation and denied migration, peer, probe, override and secret access; no keys or
  unexpected inherited IAM on the scheduling identity.
- Same-service exclusion spanning paused-dispatch verification, reconciliation of accepted requests
  and draining Cloud Run executions before updating jobs or running migrations. Scheduler HTTP
  success and pause are not application completion evidence.
- Successful rotation observed through native Cloud Run execution records and its success metric after
  installing/modifying the service policy. No prior metric history means absence monitoring is not ready.
- Exact-project/region/job alert filters, verified project-local operations channels, and a controlled
  pilot showing failure and three-hour success-gap notification (including observed zeros versus absent
  samples). Quiet alerts and Scheduler HTTP success are not completion evidence. Keep the current
  production policy until that handoff is verified; protected foundation is the sole alert writer.
- Safe resume after an approved healthy release. An interrupted or ambiguous release stays paused;
  a long maintenance pause requires a separately authorized, time-bounded alert snooze.

Keep schedules absent from disposable recovery. Recreating a schedule with an existing identity
requires revoking invocation and reconciling accepted executions before creation; fresh-resource
dependency ordering is insufficient for that case. No current production schedule changes here.

References: [Shared VPC provisioning](https://cloud.google.com/vpc/docs/provisioning-shared-vpc),
[project provisioning](./provision-workload-foundation.md), and
[architecture](../architecture.md).
