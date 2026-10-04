# Release APIs with OpenTofu

The service-release root declares Cloud Run jobs, API revisions and traffic directly in HCL.
Protected GitHub Actions owns the sequence; Cloud Run owns job execution and revision convergence.
The retained production workflow remains the live writer until an explicit ownership handoff.
The service-scoped API path is code-only and has no authenticated workflow entrypoint yet.

## Ownership

Use one OpenTofu owner for each resource. Importing an existing service into another state requires
a private state backup, an exact removal/import map, suspended old writers and a reviewed no-replacement
plan. A project move is a new resource, not an import. Confirm capacity and overlap cost before
creating it; project shells alone do not establish that compute already exists.

Both API components of one service repository use that service's single private database VM.
Routine releases must not replace, restart or reconfigure it. Foundation owns database maintenance;
pgBackRest owns backup and recovery. Keep the working backups until native protection has passed
a restore drill.

## Release sequence

1. Verify the selected producer image family and provenance, immutable destination digests, enabled
   numeric secret versions and the approved foundation coordinates.
2. Review the HCL plan for the selected scope. Apply only that saved private plan after approval,
   under the existing service guard and OpenTofu's native state lock.
3. Reconcile the exact migration job definition and execute it once. Require successful native
   execution evidence before promoting the application.
4. Deploy the candidate with the preceding healthy revision still receiving all ordinary traffic.
   Check the candidate from an authorized network using the existing health capability.
5. Review and apply the traffic-only promotion plan. Check serving health and retain the exact
   revision, input pins and successful execution evidence before releasing admission.

The [service-release inputs](../../environments/service-release#api-revisions-and-traffic) make candidate
and serving revision names explicit. They use native
[Cloud Run traffic targets](https://docs.cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration),
not a second rendering or rollout service. A failed candidate keeps traffic on the preceding revision.
Traffic rollback requires schema compatibility and does not undo migrations or recover data.

A first deployment has no preceding healthy revision. Treat it as explicit activation with a
maintenance/cost review, not an ordinary candidate promotion. JSON Keys REST is not enrolled in the
committed producer image family and remains blocked by preflight.

## Interrupted operations

Keep the existing service guard when a mutation outcome is unknown. Native GCS locking protects
one OpenTofu operation; it does not cover a Cloud Run job that continues after a runner disappears.
GitHub concurrency likewise cannot establish whether that job completed.

Use the recorded Cloud Run operation/execution and the saved inputs to reconcile a migration.
Never select the newest execution, erase intent, or rerun a migration merely because a workflow
timed out. An unavailable operation or lost dispatch response requires an attended decision.
The replacement workflow must preserve this boundary before activation.

A saved-plan or traffic apply failure requires a fresh read-only plan and review of actual Cloud Run
state. Preserve private state, plans, receipts and existing backup evidence. Do not delete an old
owner or disable its recovery readers to make a handoff appear complete.

## Why this shape

Google recommends [small root modules](https://docs.cloud.google.com/docs/terraform/best-practices/root-modules)
with clear lifecycle boundaries. The GCS backend supplies
[native state locking](https://opentofu.org/docs/language/settings/backends/gcs/), and Cloud Run
supplies revision and traffic management. Custom code remains only where those mechanisms do not
cover an existing safety requirement: provenance verification, private plan custody, host preservation
and ambiguous job reconciliation. No extra VM, controller, renderer or probe fleet is required by
this release model.
