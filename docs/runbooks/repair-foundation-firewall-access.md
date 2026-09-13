# Repair foundation firewall access

Use this procedure when a foundation apply fails with `compute.firewalls.create`,
`compute.firewalls.update`, or `compute.firewalls.delete` permission denied.
Check Cloud Audit Logs for the foundation identity; a generic failed apply is not enough.

The foundation root manages `infraFoundationFirewall`, a workload-project custom role containing
only those three write permissions. `roles/compute.networkAdmin` supplies firewall reads.
The grant belongs to the foundation identity, or to the recovery identity inside its replacement
project. Release and runtime identities receive none of it.

Firewall declarations depend on that grant. This orders API calls but does not guarantee IAM
propagation. A firewall removed from configuration may also be deleted before a newly added grant
exists. The temporary grant below covers that interrupted-rollout case without changing state or
restoring Owner. It is separate from the role OpenTofu owns.

## 1. Prepare the approved retry

Merge the corrective PR with `allow-resource-deletion` when the remaining plan deletes the old
firewall. Hold other merges until the apply finishes. Keep releases disabled and leave the paused
database schedules paused. Do not restart or recreate a retired database host.

Run from the repository root, in one operator session:

```sh
git switch master
git pull --ff-only
. ./.envrc
./ops/verify-operator-env.sh
gh variable get PRODUCTION_RELEASES_ENABLED --repo a-novel/infra
```

Continue only if the last command prints `false` and no infrastructure workflow is active.
These commands require a workload-project administrator with custom-role create/get/delete and
project IAM get/set permissions. If access is denied, have that administrator perform this section;
do not grant yourself a broader role.

All repair values are derived from `.envrc` and UTC time. Keep them in this session for cleanup;
do not add them to `.envrc`. Generate them once per repair attempt:

```sh
FIREWALL_REPAIR_ROLE_ID="infraFirewallRepair$(date -u +%Y%m%d%H%M%S)"
FIREWALL_REPAIR_ROLE="projects/${INFRA_WORKLOAD_PROJECT_ID:?}/roles/${FIREWALL_REPAIR_ROLE_ID}"
FOUNDATION_MEMBER="serviceAccount:infra-foundation@${INFRA_MANAGEMENT_PROJECT_ID:?}.iam.gserviceaccount.com"
FIREWALL_REPAIR_EXPIRES="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
FIREWALL_REPAIR_CONDITION="expression=request.time < timestamp('${FIREWALL_REPAIR_EXPIRES}'),title=FoundationFirewallRepair"
```

## 2. Grant only the missing writes for one hour

Run each command separately and stop on failure. If interrupted after creating the role, reuse
the same session values and continue at the first unfinished command.

```sh
gcloud iam roles create "${FIREWALL_REPAIR_ROLE_ID:?}" --project="${INFRA_WORKLOAD_PROJECT_ID:?}" --title='Temporary foundation firewall repair' --description='Remove after the reviewed foundation retry, including on failure.' --permissions=compute.firewalls.create,compute.firewalls.delete,compute.firewalls.update --stage=GA
```

```sh
gcloud projects add-iam-policy-binding "${INFRA_WORKLOAD_PROJECT_ID:?}" --member="${FOUNDATION_MEMBER:?}" --role="${FIREWALL_REPAIR_ROLE:?}" --condition="${FIREWALL_REPAIR_CONDITION:?}" --quiet >/dev/null
```

Inspect the exact role and binding:

```sh
gcloud iam roles describe "${FIREWALL_REPAIR_ROLE_ID:?}" --project="${INFRA_WORKLOAD_PROJECT_ID:?}" --format='yaml(name,includedPermissions,stage)'
gcloud projects get-iam-policy "${INFRA_WORKLOAD_PROJECT_ID:?}" --format=json | jq --arg role "${FIREWALL_REPAIR_ROLE:?}" --arg member "${FOUNDATION_MEMBER:?}" '.bindings[] | select(.role == $role and (.members | index($member)))'
```

Confirm the role has exactly the three permissions above and the binding names only the foundation
identity with the displayed expiry. Allow IAM propagation before proceeding: policy changes usually
take two minutes, but can take seven minutes or longer. A visible binding is not proof of effective
permission. Never test it by creating or deleting an unreviewed firewall.

## 3. Create and review a fresh foundation plan

Failed applies consume their saved plans and may already have changed resources. Never rerun the
failed apply or reuse its plan ID. This command captures the new ID without editing an example:

```sh
FOUNDATION_PLAN_ID="$(./ops/run-workflow.sh foundation plan foundation)"
```

Review the private plan before continuing. For an interrupted database split, expect the narrow
managed role/binding and remaining firewall changes. Stop for unexpected VM, disk, project, secret,
or service replacements. Leave the new hosts and preserved SSDs in place.

```sh
./ops/run-workflow.sh foundation apply foundation "${FOUNDATION_PLAN_ID:?}"
```

Approve the protected environment when prompted. Success includes the zero-change convergence
check. If permission is still denied, inspect the exact audit error and allow propagation; do not
replay the consumed plan. Proceed to cleanup after either success or failure.

## 4. Remove the repair grant

Remove this binding even if the retry failed or the one-hour expiry passed:

```sh
gcloud projects remove-iam-policy-binding "${INFRA_WORKLOAD_PROJECT_ID:?}" --member="${FOUNDATION_MEMBER:?}" --role="${FIREWALL_REPAIR_ROLE:?}" --condition="${FIREWALL_REPAIR_CONDITION:?}" --quiet >/dev/null
```

Confirm no binding references this temporary role. Continue only if this prints `true`:

```sh
gcloud projects get-iam-policy "${INFRA_WORKLOAD_PROJECT_ID:?}" --format=json | jq -e --arg role "${FIREWALL_REPAIR_ROLE:?}" 'all(.bindings[]; .role != $role)'
```

Delete only the now-unbound temporary role:

```sh
gcloud iam roles delete "${FIREWALL_REPAIR_ROLE_ID:?}" --project="${INFRA_WORKLOAD_PROJECT_ID:?}" --quiet
```

After a successful apply, inspect `infraFoundationFirewall` and its binding with the same role and
policy commands, using `infraFoundationFirewall` as the role ID. It must contain the same three
permissions and name only the foundation account. Recheck the database hosts, startup services,
private API access, and firewall rules before resuming the rebuild. A running VM alone does not
prove PostgreSQL is initialized. Keep releases and schedules paused until their rollout checks pass.

If the session was lost, find the `FoundationFirewallRepair` binding in the workload project's IAM
policy; its role name and expiry identify the cleanup targets. Do not remove unrelated bindings or
delete the permanent `infraFoundationFirewall` role.

## References

- [Compute Engine IAM roles](https://docs.cloud.google.com/compute/docs/access/iam)
- [Create a custom role](https://docs.cloud.google.com/sdk/gcloud/reference/iam/roles/create)
- [IAM access-change propagation](https://docs.cloud.google.com/iam/docs/access-change-propagation)
