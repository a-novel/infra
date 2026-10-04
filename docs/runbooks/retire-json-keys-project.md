# Retire the obsolete JSON Keys project

This procedure retires only `a-novel-json-keys-prod` (number `111523090533`) under organization
`1031663934757`. It preserves `a-novel-production-prod`, its Shared VPC host, both database hosts,
disks, backups, secrets and applications. Management storage and evidence remain retained.
It provisions no replacement project or paid runtime. The operator may explicitly delegate these
steps; GitHub's existing protected plan/apply and exact-commit deletion gates still apply.

## Establish the retirement boundary

Use clean, current `master` and the repository-pinned OpenTofu/provider versions. Recheck queued
Renovate merges, active writers, private custody and state ownership before each plan. Preserve a
generation-bound private state backup. Confirm the exact project identity and parent, no workloads
or user data, and that this is the sole registered/attached service project. Denied or partial reads
are not evidence of absence. Inventory its management-side state and receipt prefixes, including
versions; any active operation or initialized service root requires separate reconciliation.

Keep service provisioning, native backups and recovery activation disabled. Fetch the current
complete protected foundation configuration and preserve its existing values, including
`legacy_backup_job_access`, principals and alert settings. The publisher replaces both protected
environment documents. The recovery compiler removes retirement authorization from disposable
inputs. The production selection rejects future project registrations; a successor configuration
must preserve the Shared VPC host explicitly.

## Prepare persistent provider guards

Publish `retire_json_keys_project = true` while retaining
`service_projects = { "json-keys": "a-novel-json-keys-prod" }` and an empty
`pgbackrest_repository_services`. Source `.envrc`, then use the existing `foundation-setup configure`
publisher with `--retire-json-keys-project`,
`--service-projects '{"json-keys":"a-novel-json-keys-prod"}'`, `--public-api-project-id ''`,
`--public-project-id ''` and all existing configuration options. The current `.envrc` selects the
successor trust-zone shells, not this historical retirement operation. Do not use these overrides to
retire an already provisioned trust-zone project, publish a map-only replacement or infer absent settings.

Run the protected `foundation plan foundation` operation and inspect the exact private plan.
Preparation may only change the obsolete project's persistent deletion policies and disable its
unused release identity/federation. Require no creates, deletes, replacements or production changes.
Apply that saved plan through the existing workflow and verify convergence before proceeding.

Provider `PREVENT` is the default guard for project-shell resources and survives removal of a
`for_each` module instance. Preparation persists `DELETE` for the empty project and release
identity/provider, and `ABANDON` for the default log bucket and management custody folders.
These are apply-time guards; the reviewed plan gate still covers removal. Folder `force_destroy`
remains false. Log retention is not shortened; project shutdown determines the project's log fate.

## Remove the obsolete registration

Publish the same complete configuration with `service_projects = {}` and retirement still true.
Run a fresh protected plan. Require only the obsolete module, attachment and its cross-project IAM
to be removed, the obsolete number to leave the existing budget filter, and the unused probe tag
to leave the restricted-HTTPS rule. Budget amount/thresholds and all remaining firewall selectors
must be unchanged. The production Shared VPC host must remain a no-op; do not disable it.
Reject any other change, import or replacement. Custody folders leave state through `ABANDON`;
their objects are not deleted. Record their exact retained paths privately.

Before applying, verify effective deletion authority. The authorized temporary Shared VPC Admin
grant belongs to `infra-foundation@a-novel-management-prod.iam.gserviceaccount.com` at the stated
organization, with an expiry of at most two hours. Project Deleter belongs only on the obsolete
project. Save baseline policies and exact conditions before granting. Add neither Owner nor
Project Creator nor Billing User. If teardown removes the foundation's own project-IAM, role or
service-account administration before dependent deletes complete, separately record short-lived
conditional copies of those already-held exact-project roles; do not broaden their permissions.
Review the exact additions before apply and remove them on success or failure. Missing authority
outside this boundary requires approval.

Apply only the reviewed saved plan at its bound commit. Native dependencies must detach the
service project before project shutdown. Keep private diagnostics and accepted state on failure;
never replay a consumed plan, edit raw state, or remove state entries to bypass a failed delete.
Request a fresh reviewed plan only after reconciling accepted work and any operation guard.

## Verify completion and remove temporary access

Verify `DELETE_REQUESTED` for the exact project and no host-side Shared VPC attachment. Confirm
both production database identities/disks/private addresses and application health are unchanged.
Inspect retained custody metadata and confirm obsolete release access is revoked. Remove only
the temporary bindings recorded for this operation, preserving baseline access; expiration alone
does not remove a binding. If Google rejects IAM edits after shutdown, retain that error and verify
the expiry; do not undelete the project merely to remove an expired binding.

With temporary organization authority removed, require a fresh zero-change foundation plan and
verify converged configuration no longer registers the obsolete project. Retain the retirement
selection until its successor preserves the host. Keep retained management folders/evidence under
their existing retention policy. `DELETE_REQUESTED` is pending shutdown, not immediate permanent
erasure or immediate quota availability; inspect billing separately before claiming zero charges.

References: [Shared VPC deprovisioning](https://docs.cloud.google.com/vpc/docs/deprovisioning-shared-vpc),
[project shutdown](https://docs.cloud.google.com/resource-manager/docs/creating-managing-projects#shutting_down_projects),
and the [provider's project guard](https://github.com/hashicorp/terraform-provider-google/blob/v8.5.0/google/services/resourcemanager/resource_google_project.go).
