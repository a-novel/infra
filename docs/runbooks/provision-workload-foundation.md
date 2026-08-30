# Provision the workload foundation

This runbook creates the production project, private network, identities, PostgreSQL host,
registry, budgets, and alerts. It does not deploy application containers or secret payloads.

Stop if another production infrastructure workflow is active. Keep
`PRODUCTION_RELEASES_ENABLED=false` throughout this runbook.

## Prerequisites

Run from the repository root with `gh`, `gcloud`, and `jq` authenticated:

```sh
. ./.envrc
./ops/verify-operator-env.sh

git switch master
git pull --ff-only
git status --short

./ops/verify-repository-gate.sh
```

Expected: both verification scripts pass, `master` is current, `git status` prints nothing, and
the production release switch is disabled.

## 1. Grant temporary provisioning access

Use the management project's parent:

```sh
./ops/foundation.sh grant
```

Use a specific folder only when the workload project belongs there:

```sh
./ops/foundation.sh grant --folder-id 123456789012
```

For a parentless project:

```sh
./ops/foundation.sh grant --standalone --adopt-existing-project
```

Add `--adopt-existing-project` to the organization or folder command when the workload project
already exists. Reuse the same parent option in steps 2 and 7.

Expected: `PASS temporary foundation access`. Stop on an ambiguous permission error; do not guess
whether a project ID is available.

## 2. Publish the protected configuration

The defaults are `europe-west1`, `europe-west1-c`, `10.20.0.0/24`, and the active Google user for
alerts, database operations, and Authentication initialization:

```sh
./ops/foundation.sh configure
```

Override only deliberate choices:

```sh
./ops/foundation.sh configure \
  --database-zone europe-west1-c \
  --cost-alert-email operations@example.com \
  --operations-alert-email operations@example.com \
  --database-operator-principal group:database-operators@example.com \
  --auth-initializer-principal group:authentication-initializers@example.com
```

Add the step 1 parent option when it was explicit. Add `--adopt-existing-project` only for an
existing project.

Expected:

```text
PASS protected foundation environment
PASS protected foundation configuration
```

In **Settings > Environments > production-foundation**, confirm **Prevent administrators from
bypassing protection rules** is enabled. GitHub does not expose this switch reliably through its
API.

## 3. Reconcile the management bootstrap

```sh
./ops/run-workflow.sh foundation plan bootstrap
```

Review the sanitized counts. If the plan has changes, apply its exact printed ID:

```sh
./ops/run-workflow.sh foundation apply bootstrap 1234567890-1
```

Skip the apply when the plan has no changes. Never infer, edit, or reuse a plan ID.

## 4. Apply the workload foundation

```sh
./ops/run-workflow.sh foundation plan foundation
```

Review the sanitized counts. Stop for any unexpected deletion, replacement, state-forget, public
IP, router/NAT, VPC connector, load balancer, Cloud Run workload, secret version, or
service-account key. A deletion or replacement requires a fresh plan from a PR merged with the
`allow-resource-deletion` label.

Apply only the printed ID:

```sh
./ops/run-workflow.sh foundation apply foundation 1234567890-1
```

Success includes a zero-change convergence plan. Do not repeat a successful apply.

If a manually created project contains Google's empty `default` VPC, stop. Use the reviewed
two-PR adoption and deletion path; never import or delete it locally.

## 5. Audit the deployed boundary

Grant temporary read access:

```sh
./ops/foundation.sh grant-audit-access
```

After IAM propagation:

```sh
./ops/foundation-audit.sh
```

Always remove the grant, including after failure:

```sh
./ops/foundation.sh revoke-audit-access
```

Expected: every audit line begins with `PASS`; cleanup prints
`PASS temporary audit access removed`. On `PERMISSION_DENIED`, wait and rerun only the audit.
Do not grant a broader role.

The audit checks project and billing identity, managed APIs, IAM and service-account keys, Secret
Manager allowlists, backup/restore separation, Cloud Run invocation boundaries, the private
network, firewall and route allowlists, absence of public or fixed-cost network products, and the
immutable production registry.

## 6. Enforce the service-account organization policies

Derive the organization and active operator:

```sh
ORGANIZATION_ID="$(gcloud projects get-ancestors "$INFRA_WORKLOAD_PROJECT_ID" \
  --filter='type=organization' --format='value(id)')"
OPERATOR_PRINCIPAL="user:$(gcloud config get-value account 2>/dev/null)"

printf 'Organization: %s\nOperator: %s\n' \
  "$ORGANIZATION_ID" "$OPERATOR_PRINCIPAL"
```

If `Organization` is empty, record the standalone exception and continue to step 7. Do not create
an organization solely for this deployment.

Inspect the effective policies:

```sh
for CONSTRAINT in \
  iam.automaticIamGrantsForDefaultServiceAccounts \
  iam.disableServiceAccountKeyCreation \
  iam.disableServiceAccountKeyUpload; do
  gcloud resource-manager org-policies describe "$CONSTRAINT" \
    --project="$INFRA_WORKLOAD_PROJECT_ID" \
    --effective \
    --format='value(constraint,booleanPolicy.enforced)'
done
```

Expected: all three lines end in `True`. If they do, skip directly to step 7.

If any policy is not enforced, an organization administrator grants the active operator temporary
Organization Policy Administrator:

```sh
gcloud organizations add-iam-policy-binding "$ORGANIZATION_ID" \
  --member="$OPERATOR_PRINCIPAL" \
  --role='roles/orgpolicy.policyAdmin' \
  --condition=None
```

After IAM propagation, run only the missing policy commands:

```sh
gcloud resource-manager org-policies enable-enforce \
  iam.automaticIamGrantsForDefaultServiceAccounts \
  --project="$INFRA_WORKLOAD_PROJECT_ID"

gcloud resource-manager org-policies enable-enforce \
  iam.disableServiceAccountKeyCreation \
  --project="$INFRA_WORKLOAD_PROJECT_ID"

gcloud resource-manager org-policies enable-enforce \
  iam.disableServiceAccountKeyUpload \
  --project="$INFRA_WORKLOAD_PROJECT_ID"
```

Always remove the temporary organization-wide role, including after a failed policy command:

```sh
gcloud organizations remove-iam-policy-binding "$ORGANIZATION_ID" \
  --member="$OPERATOR_PRINCIPAL" \
  --role='roles/orgpolicy.policyAdmin' \
  --condition=None
```

Repeat the inspection command until all three lines end in `True`. Policy propagation can take up
to 15 minutes. Stop if the temporary role cannot be removed.

## 7. Remove provisioning access

Continue only after both roots converge, step 5 passes, the step 6 decision is recorded, and the
[PostgreSQL host](./operate-postgresql-host.md) has one private address, no external address, its
preserved disk, and no running database container.

```sh
./ops/foundation.sh finish
```

Use the same explicit parent option as steps 1-2. The command removes temporary Owner, Billing
Account User, and Project Creator access, then publishes the workload project ID.

Run the final audit:

```sh
./ops/foundation.sh grant-audit-access
./ops/foundation-audit.sh --final
./ops/foundation.sh revoke-audit-access
```

Expected: every audit check passes and `GCP_WORKLOAD_PROJECT_ID` matches
`INFRA_WORKLOAD_PROJECT_ID`.

Record only workflow URLs, opaque plan IDs/checksums, the project number, timestamp, and named
`PASS` results. Never record billing IDs, email addresses, IAM dumps, plan values, or secrets.

## Resume after a stop

| Last result                              | Resume                                                                                         |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Temporary grants complete                | Step 2.                                                                                        |
| Configuration complete                   | Step 3.                                                                                        |
| Plan succeeded, apply absent             | Apply that exact unexpired ID.                                                                 |
| Deletion-label gate rejected the plan    | Merge another labeled PR, refresh `master`, and create a fresh plan.                           |
| Apply failed                             | Merge the correction, refresh `master`, and create a fresh plan.                               |
| Apply succeeded                          | Step 5; do not repeat the apply.                                                               |
| Audit permission denied                  | Wait for propagation and rerun only the audit.                                                 |
| Audit failed                             | Revoke access, correct through reviewed plan/apply, then repeat step 5.                        |
| Organization policy update failed        | Remove the temporary role, correct the error, then repeat step 6.                              |
| `finish` partly completed                | Rerun `finish`; it removes only bindings still present.                                        |
| Project exists but state does not own it | Use the reviewed `adopt_existing_project` path; never run local `tofu import`.                 |
| State owns a missing project             | Stop all mutations and follow [state recovery](./state-recovery.md).                           |
| Quota or zone exhausted                  | Change the reviewed zone or quota selection in code and create a fresh plan; do not add quota. |

## References

- [Architecture decisions](../architecture.md)
- [Google Cloud resource map](../google-cloud.md)
- [Google project hierarchy](https://cloud.google.com/resource-manager/docs/cloud-platform-resource-hierarchy)
- [Organization Policy CLI](https://cloud.google.com/sdk/gcloud/reference/resource-manager/org-policies)
- [Service-account security](https://cloud.google.com/iam/docs/best-practices-service-accounts)
- [OpenTofu saved-plan apply](https://opentofu.org/docs/cli/commands/apply/)
