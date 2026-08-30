# Provision the workload foundation

Use this guide after the management-plane bootstrap passes. It creates the replaceable production
project and its private network, identities, stateful PostgreSQL host, registry, budgets, and alerts.
Application containers and secret payloads are deliberately absent.

The operator interfaces are [`ops/foundation.sh`](../../ops/foundation.sh) for controlled mutations
and [`ops/foundation-audit.sh`](../../ops/foundation-audit.sh) for read-only acceptance. Every
invocation validates the operator-selected project IDs before reading GitHub or Google Cloud
metadata, so the same commands work for a replacement project.

## Authorization gate

The permanent configuration is applied only by [`foundation.yaml`](../../.github/workflows/foundation.yaml)
from reviewed `master`. The human commands below can only:

- publish the protected non-payload input document;
- grant and later remove the minimum project-creation and billing prerequisites;
- grant and later remove the current human's read-only Security Reviewer role;
- inspect the resulting security boundary.

Do not continue while another production infrastructure workflow is active. Do not enable
`PRODUCTION_RELEASES_ENABLED` in this guide.

## Prerequisites

Run from the repository root with `gh`, `gcloud`, and `jq` authenticated to the intended
accounts. The management bootstrap must have published `GCP_MANAGEMENT_PROJECT_ID` and
`GCP_BACKUP_BUCKET`.

Create `.envrc` once with the root
[project-coordinate setup](../../README.md#choose-the-project-coordinates), then load the reviewed
coordinates before this runbook:

```sh
. ./.envrc
./ops/verify-operator-env.sh
```

Expected: `PASS operator project coordinates`. This guide deliberately uses the local workload ID
before `finish` publishes it to GitHub.

Refresh the reviewed branch:

```sh
git switch master
git pull --ff-only
git status --short
```

Expected: `master` is current and the final command prints nothing.

Verify the repository protection once:

```sh
./ops/verify-repository-gate.sh
```

Expected: the ruleset and required checks pass, all three production environments are protected,
and `PRODUCTION_RELEASES_ENABLED=false`.

## 1. Grant the temporary provisioning boundary

For a workload project beside the management project, parent selection is automatic:

```sh
./ops/foundation.sh grant
```

The command reads the management project's parent. It grants Project Creator at that organization
or folder, Billing Account User and Costs Manager to the foundation identity, and Billing Viewer to
the read-only plan identity. It never grants Billing Administrator.

Use an explicit narrower folder only when the workload project belongs there:

```sh
./ops/foundation.sh grant \
  --folder-id 123456789012
```

When adopting an existing organization- or folder-backed project, add
`--adopt-existing-project`. The command verifies the existing project's parent before granting the
foundation identity temporary Owner; `finish` removes that role.

For a parentless account, the operator must deliberately select the standalone path. This creates
only the empty billed project when it is absent and marks it for OpenTofu adoption:

```sh
./ops/foundation.sh grant \
  --standalone \
  --adopt-existing-project
```

Expected: `PASS temporary foundation access`. Rerunning the organization/folder form is
idempotent. A standalone retry reuses an existing visible project; stop on an ambiguous permission
error instead of guessing whether the ID is free.

Google references:
[creating projects](https://cloud.google.com/resource-manager/docs/creating-managing-projects),
[Project Creator](https://cloud.google.com/resource-manager/docs/access-control-proj),
and [Cloud Billing IAM](https://cloud.google.com/billing/docs/how-to/billing-access).

## 2. Publish the protected foundation configuration

The defaults are the reviewed low-cost production shape:

- project name `Agora production`;
- region `europe-west1`, database zone `europe-west1-c`;
- subnet `10.20.0.0/24`;
- the active Google user as cost recipient, operations recipient, database operator, and
  Authentication initializer.

Publish those defaults:

```sh
./ops/foundation.sh configure
```

The command verifies the `production-foundation` environment before writing one masked
`FOUNDATION_TFVARS_JSON` secret to `production-foundation` and `production-recovery`. It
contains billing and human-principal metadata but no application secret payload.

Specify only genuine choices. Repeated principal flags create a protected allowlist:

```sh
./ops/foundation.sh configure \
  --database-zone europe-west1-c \
  --cost-alert-email operations@example.com \
  --operations-alert-email operations@example.com \
  --database-operator-principal group:database-operators@example.com \
  --auth-initializer-principal group:authentication-initializers@example.com
```

Add the same parent option used in step 1 when it was not automatic. Add
`--adopt-existing-project` only when the project already exists; it is mandatory with
`--standalone`.

Expected:

```text
PASS protected foundation environment
PASS protected foundation configuration
```

Confirm **Settings → Environments → production-foundation → Prevent administrators from bypassing
protection rules** remains enabled. GitHub does not expose a reliable API field for this switch.

## 3. Reconcile the management bootstrap

The protected bootstrap root must converge before the workload root can mutate. Create a fresh
saved plan:

```sh
./ops/run-workflow.sh foundation plan bootstrap
```

A successful command prints an opaque plan ID such as `1234567890-1`. Review the workflow's
sanitized action counts. If it reports no changes, continue to step 4. If it reports expected
bootstrap drift, apply that exact ID:

```sh
./ops/run-workflow.sh foundation apply bootstrap 1234567890-1
```

Replace the example ID; never infer or reuse one. The helper verifies that the plan attempt
succeeded, belongs to `foundation.yaml`, and was created from the exact current local and remote
`master` commit. Plan custody enforces the root, hash, 24-hour lifetime, one-time consumption, and
the deletion-label decision recorded when the plan was created.

## 4. Plan and apply the workload foundation

Create the workload plan:

```sh
./ops/run-workflow.sh foundation plan foundation
```

Review the sanitized resource-type counts. A first organization-backed deployment should create the
project, thirteen APIs, one custom VPC/subnet, restricted Google routes and DNS, six firewall rules,
seven runtime service accounts, invocation tags and conditional IAM, one immutable Artifact
Registry repository, one preserved database disk and stateful instance group, snapshots, budgets,
quotas, logging controls, notification channels, and monitoring policies.

Stop for any unexpected deletion, replacement, state-forget, public IP, router/NAT, VPC connector,
load balancer, Cloud Run workload, secret version, or service-account key. A destructive plan must
have been created from a pull request that already carried `allow-resource-deletion` before merge.

Apply only the printed plan ID:

```sh
./ops/run-workflow.sh foundation apply foundation 1234567890-1
```

The apply consumes that plan once and finishes by proving a zero-change convergence plan. Do not
dispatch another apply when the workflow succeeds.

A manually created project can contain Google's empty `default` VPC. In that case, stop at the
plan and use the reviewed two-PR adoption path: first set `adopt_default_network=true` and import
only `google_compute_network.default_adoption`; then remove it in a separate
`allow-resource-deletion` pull request. Never delete or import that network locally.

Google references:
[Terraform operations](https://cloud.google.com/docs/terraform/best-practices/operations) and
[OpenTofu saved-plan apply](https://opentofu.org/docs/cli/commands/apply/).

## 5. Audit the deployed boundary

Grant the active Google user the predefined read-only Security Reviewer role:

```sh
./ops/foundation.sh grant-audit-access
```

Allow IAM propagation, then run the independently repeatable audit:

```sh
./ops/foundation-audit.sh
```

It fails at the first named invariant and prints no secret value. It verifies:

- workload identity, labels, billing, every managed API, and only the reviewed Google-default or
  dependency APIs beside them;
- no unexpected primitive service-account role or user-managed service-account key;
- no public or unexpected service-account Secret Manager principal;
- all nine required secret containers, with each runtime restricted to its exact payload set;
- create-only backup and read-only restore access on the recovery bucket;
- exact conditional Cloud Run invocation classes and human-only initializer deployment, tag use,
  and service-account impersonation;
- one private VPC, only the restricted routes and six reviewed firewall rules;
- no external address, router/NAT, forwarding rule, or other public/fixed-cost network product;
- immutable Artifact Registry and the exact Cloud Run invocation-tag classes.

Remove the temporary reviewer even when the audit fails:

```sh
./ops/foundation.sh revoke-audit-access
```

Expected: every line begins with `PASS`; the cleanup ends with
`PASS temporary audit access removed`. A propagation-time `PERMISSION_DENIED` is a reason to
retry the read-only audit, not to grant a broader role.

OpenTofu's post-apply convergence remains the authoritative exact-resource/IAM comparison. This
audit covers high-impact independent invariants that are easy to miss in a plan summary.

## 6. Enforce organization policies when an organization already exists

Inspect these effective constraints in Google Cloud Console or with the
[Organization Policy CLI](https://cloud.google.com/resource-manager/docs/organization-policy/creating-managing-policies):

- `iam.automaticIamGrantsForDefaultServiceAccounts`;
- `iam.disableServiceAccountKeyCreation`;
- `iam.disableServiceAccountKeyUpload`.

For an organization-backed project, all three must be enforced. If one is missing, an organization
administrator temporarily grants the named operator `roles/orgpolicy.policyAdmin`; the operator
enforces only the missing constraint at the workload project; the administrator immediately removes
the role. Keep those grant/enforce/revoke actions separate so the broad role is removed even after a
failed policy update.

For a standalone project, record that organization policies are unavailable. Rely on the
code-managed default-account deprivileging, the zero-key audit above, short-lived Workload Identity
Federation, and periodic drift audits. Do not create an organization solely for this deployment.

This remains a deliberate manual security gate: the repository must not automate granting itself
organization-wide policy authority.

## 7. Remove one-time authority and publish the workload coordinate

Run only after:

- both protected roots converge;
- step 5 passes;
- the organization-policy decision is recorded;
- [the private PostgreSQL host](./operate-postgresql-host.md) has one private address, no external
  address, its preserved disk, and no running database container.

Remove only the temporary Owner, Billing Account User, and parent Project Creator bindings, then
publish the verified project ID:

```sh
./ops/foundation.sh finish
```

Use the same explicit parent option as steps 1–2 when automatic parent selection was not used.
Costs Manager and the plan identity's Billing Viewer intentionally remain.

Run the final audit with temporary read access:

```sh
./ops/foundation.sh grant-audit-access
./ops/foundation-audit.sh --final
./ops/foundation.sh revoke-audit-access
```

Expected: the final primitive-role check passes, all other audit checks remain green, and
`GCP_WORKLOAD_PROJECT_ID` equals the selected project.

Record only the workflow URLs, opaque plan IDs/checksums, project number, timestamp, and named PASS
results in the private deployment record. Do not record billing IDs, email addresses, IAM dumps,
plan values, or secret material.

## Resume and failure map

| Last result                                     | Resume                                                                                         |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Temporary grants complete, configuration absent | Step 2; `configure` safely replaces the protected document.                                    |
| Configuration complete, no plan                 | Step 3.                                                                                        |
| Plan succeeded, apply absent                    | Review and apply that exact unexpired ID; do not create another plan.                          |
| Apply failed                                    | Use its sanitized reason, merge the correction, refresh `master`, and create a new plan.       |
| Apply succeeded                                 | Step 5; never repeat the successful apply.                                                     |
| Audit permission denied                         | Confirm the exact Security Reviewer binding, wait for propagation, rerun only `audit`.         |
| Audit failed                                    | Revoke audit access, correct through a reviewed plan/apply, then repeat step 5.                |
| Finish partly completed                         | Rerun `finish`; it removes only bindings that are still present.                               |
| Project exists but state does not own it        | Stop. Use the reviewed `adopt_existing_project` import path; never run local `tofu import`.    |
| State owns a missing project                    | Stop all mutations and follow [state recovery](./state-recovery.md).                           |
| Google reports quota or zone exhaustion         | Do not add capacity. Use the approved alternate zone/metric fix in code and create a new plan. |

## References

- [Architecture decisions](../architecture.md)
- [Google Cloud resource map](../google-cloud.md)
- [Google project hierarchy](https://cloud.google.com/resource-manager/docs/cloud-platform-resource-hierarchy)
- [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation)
- [Secret Manager access control](https://cloud.google.com/secret-manager/docs/access-control)
- [VPC firewall rules](https://cloud.google.com/firewall/docs/firewalls)
