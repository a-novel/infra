# Release APIs with OpenTofu

The service-release root declares Cloud Run jobs, API revisions and traffic directly in HCL.
Protected GitHub Actions owns the sequence; Cloud Run owns job execution and revision convergence.
Authentication runs in public-api; JSON Keys gRPC and the three existing migration and rotation jobs
run in private. Their service-release roots own these resources through the protected foundation
workflow's plan/apply path. Native releases also adopt the existing JSON Keys health probe.
The retained release root owns its invocation tag, scheduler and backup resources. The old
deployment orchestrator stays disabled.

The production release workflow's manual `plan` and `apply` actions reconcile that retained root
from its last converged private inputs, without running migrations or the old rollout machinery.
They share production concurrency, protected approval and saved-plan custody. Review the full plan
before applying. Scheduled health checks select the registered public-api project.

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
3. Set `migration_image` to the selected family's exact private migration digest. Cloud Run's
   `run_execution_token` makes the private job update wait for that named execution's success.
   Authentication's private apply must complete before its public-api apply; the latter independently
   checks that same migration image, task template, token and successful execution.
4. Deploy the candidate with the preceding healthy revision still receiving all ordinary traffic.
   Check the candidate from an authorized network using the existing health capability.
5. Review and apply the traffic-only promotion plan. Check serving health and retain the exact
   revision, input pins and successful execution evidence before releasing admission.

The [service-release inputs](../../environments/service-release#api-revisions-and-traffic) make candidate
and serving revision names explicit. They use native
[Cloud Run traffic targets](https://docs.cloud.google.com/run/docs/rollouts-rollbacks-traffic-migration),
not a second rendering or rollout service. A failed candidate keeps traffic on the preceding revision.
Traffic rollback requires schema compatibility and does not undo migrations or recover data.

### Protected inputs and activation

Keep `SERVICE_JOB_BOOTSTRAPS_JSON` entries keyed by `authentication/private`,
`authentication/public-api` and `json-keys/private`. Select the matching `service` and `zone`
in the existing foundation workflow; `zone=none` retains the older service-only configuration
selection. Each entry remains an ordinary service-release tfvars object. Use the existing image
promotion action, followed by `plan` and `apply`; no new deployment engine is involved.

Before first native JSON Keys activation, back up both states, apply the retained release root's
exact non-destructive probe removal, then import the same `agora-json-keys-smoke` job with
`adopt_existing_jobs=true`. The plan policy rejects probe creation or replacement. Apply the
foundation's scoped release-job permission and the private service foundation's exact JSON Keys
self-invocation grant first. Do not enable routine execution while two
states still own the probe.

The retained-root plan must contain exactly one `forget` for
`google_cloud_run_v2_job.json_keys_smoke[0]`. The native private JSON Keys plan imports that same
`agora-json-keys-smoke` job as `google_cloud_run_v2_job.verification[0]`; reject creation,
replacement or deletion. Record its Cloud Run UID before removal and confirm the UID after import.
Its invocation tag stays in the retained root. Preserve both state backups until the native
probe has completed successfully and the new root converges.

State removal requires `allow-resource-deletion` on the PR that produced the workflow's exact
master commit, present before that PR merged. Finish pending dependency merges before landing
the approved handoff PR and creating its plan. If master advances again, obtain approval through
a reviewed PR on the new base; adding a label after merge cannot authorize that commit.

Pause `agora-json-keys-rotation` before a JSON Keys release and wait for accepted executions to
finish. The guarded apply verifies that the schedule is paused and every listed execution has
finished. Leave it paused between candidate and promotion, or after failure; resume it only after
successful promotion and serving verification. Retain the schedule's existing configuration owner
and avoid reconciling that legacy root during this interval.

The API candidate plan sets a new `api.revision` while preserving `api.serving_revision`.
The promotion inputs must be byte-equivalent JSON values to the last checked candidate except
for setting `api.serving_revision` to that candidate. Changing secrets, images or other
configuration requires a new candidate first. The promoted revision keeps the candidate tag so
the existing private probe verifies the same revision after traffic changes.

The native migration token is derived from the exact migration image; the probe token is derived
from the candidate/serving configuration. Never invent another token to retry a lost operation.
An unchanged token is not a general exactly-once guarantee. A changed migration template with an
already-used token requires reconciliation, not automatic invocation. Keep `migration_image=null`
only for reviewed definition-only bootstrap, not as a way around a failed routine release.

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
The routine path records successful execution names/UIDs and checked revision identities in its
private completion receipt. It performs no cleanup unlock on an ambiguous apply, failed health
check or incomplete publication. A post-promotion health failure may leave the new revision
serving: inspect it and select a schema-compatible rollback explicitly.

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
