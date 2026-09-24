# Service-operation contract

**Contract for the inactive service-owned pilot, not a production guarantee.**
This contract advances [interrupted-release recovery](https://github.com/a-novel/infra/issues/189)
and [ownership transfer](https://github.com/a-novel/infra/issues/187). Implementation and live
activation remain separate review gates.

## What exists, and what is missing

The current [foundation](../.github/workflows/foundation.yaml) and
[release](../.github/workflows/release.yaml) workflows serialize production writes through
`production-infrastructure`. Keep that working boundary until every replacement writer participates.
The pilot's [submission commands](runbooks/submit-release.md) preserve immutable intent, dispatch
once, and reconcile exact native operations. They do not yet reserve a service across different
release IDs, foundation changes, job updates, scheduled work or final receipt publication.

An **operation** is one reviewed change to one service, including the work needed to leave it in a
known state. A **guard** admits that operation and blocks another. A **request intent** prevents replay
of one mutation. Native **execution evidence** establishes what actually happened. None substitutes
for the others, and successful rendering is not a completed deployment.

### Implemented: service-root apply

The protected foundation workflow uses `infra custody plan apply` for both `service-foundation`
and create-only `service-release` bootstrap. It validates registration, activation and workflow
identity, snapshots the private inputs, and verifies their exact hash against the saved plan.
It then acquires the shared service guard before consuming the plan, applying it and checking
zero-change convergence. Neither root can publish configuration through the standalone
`infra custody config publish` command.

On success, the same process creates the converged configuration in its existing namespace,
then an immutable completion object at `services/PROJECT/production/operations/GENERATION.json`
in the receipt bucket. The record binds the reviewed plan/input hashes, workflow run/attempt,
acknowledged guard generation and configuration generation. **This proves apply convergence,
not application health or a completed release/recovery.** Only then may the process delete its
exact live guard generation. These writes use the existing foundation bucket authority.

Any failed or uncertain step after admission leaves the service blocked. A lost delete response
also returns non-success even if removal committed; inspect the exact completion and generation,
not just the workflow status. Cancellation stops local child processes but cannot recall accepted
cloud operations. There is no unlock, takeover, expiry or automatic retry command. Read-only
assessment/drift refuses either service root while a guard is present, including before first state.

This is the first enrolled writer, **not end-to-end service exclusion**. Native submissions,
scheduled work, shared-root changes and protected recovery still need the boundaries below.
Both pilot activation flags remain off by default; legacy production retains its existing global
serialization and configuration/receipt owners. Do not activate competing writers on this basis.

## One owner for each responsibility

| Responsibility                                                         | Owner                          | Boundary                                                                                                    |
| ---------------------------------------------------------------------- | ------------------------------ | ----------------------------------------------------------------------------------------------------------- |
| Projects, IAM, private networking, database hosts/disks                | Protected OpenTofu foundation  | Participates in exclusion for every affected service; not routine release authority.                        |
| Selected application job specifications                                | OpenTofu service-release state | Bootstrap is create-only today; routine updates need an explicit writer handoff.                            |
| Rotation schedule definition and invocation IAM                        | OpenTofu service foundation    | Creates paused; transfers operational pause/resume ownership explicitly before activation.                  |
| Migrations and rotation executions                                     | Cloud Run Jobs                 | Caller controls admission and records exact execution evidence; migrations remain outside retry hooks.      |
| Complete API specification, revisions, traffic, deploy/verify progress | Cloud Deploy                   | Sole API writer after handoff; no parallel Go traffic controller.                                           |
| Admission, scheduler pause/drain, final evidence                       | Small trusted Go caller        | Coordinates boundaries, not a second implementation of native rollout phases.                               |
| Review, bounded tracking and operator handoff                          | GitHub Actions                 | Waits for the exact deployment and verification; reports required action or unknown outcome as non-success. |
| Alerts when the runner is unavailable                                  | Native Google Cloud monitoring | Notification is not recovery evidence or authority to release a guard.                                      |

The dormant pilot database is still foundation-owned. This contract does not authorize a routine
writer to change its metadata or declare it ready. Database activation, backup proof and maintenance
ownership remain gates in the [service-foundation contract](../environments/service-foundation/README.md).
Application compensation never restores an old database backup or reverses concurrent writes.

## Use existing mechanics; add only service admission

| Existing mechanism                                                                                                                      | Keep it for                                | Why it does not cover the whole operation                                        |
| --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | -------------------------------------------------------------------------------- |
| [GitHub concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency) | Serializing live trusted writer jobs       | Its lifecycle is the GitHub job/run, not accepted work still running in Google.  |
| OpenTofu backend lock                                                                                                                   | Protecting one state transaction           | Separate roots and post-apply migrations/rollouts are outside that lock.         |
| [Cloud Deploy](https://docs.cloud.google.com/deploy/docs/architecture)                                                                  | Native rollout execution and recovery      | It does not own foundation changes, external migrations or our recovery receipt. |
| Immutable release/request intents                                                                                                       | One-shot dispatch and later reconciliation | Another release ID can reserve different intents for the same service.           |

The admission primitive is **one persistent guard object per service**, using the existing official
Storage client. Its location is `services/PROJECT_ID/release/operation.json` in the state
bucket, inside the service's existing release-state namespace. It is not a receipt, Terraform state
or renewable lease. No new database, queue, coordination platform or expiry worker is needed.

Acquire with [GCS generation preconditions](https://docs.cloud.google.com/storage/docs/request-preconditions):
create only when no live object exists, then retain the returned generation. The small, private record
binds the approved project/service/region, operation kind, commit, GitHub run/attempt and, for a release,
its predetermined release ID. It contains no credentials or secret payloads. A new automated operation
needs an acknowledged acquisition before dispatch. A lost acknowledgement requires reconciliation, not a second
acquisition or automatic adoption of matching content.

The guard has **no TTL, automatic takeover or unconditional cleanup handler**. Finishing deletes only
its exact generation, after the completion conditions below. An ambiguous delete is resolved by
inspecting that generation and its completion evidence, never by deleting the current object by name.
Native generation checks provide the storage primitive; Agora retains only the admission policy.

This is a cooperative trusted-tooling boundary, **not fencing of other cloud APIs**: a GCS generation
cannot invalidate a delayed Cloud Run or Cloud Deploy request. All mutating callers must participate.
Privileged console access and IAM administrators remain explicit human coordination boundaries.

## One operation from admission to completion

1. **Authorize and admit.** Resolve the reviewed service/foundation, exact images and provenance,
   enabled secret-version metadata, and intended operation. Enter the writer concurrency group and
   acquire the guard before changing managed resources or executing work. Repeat checks at their consumption
   boundaries; the guard cannot prevent an administrator changing a secret version.
2. **Quiesce competing scheduled work.** Pause the selected schedule, reconcile already accepted
   dispatch requests and drain their Cloud Run executions before changing jobs or schema. A paused
   schedule, an HTTP acknowledgement or one empty execution list is not proof of quiescence. If an
   accepted dispatch cannot be accounted for, stop with the guard held. Do not invent a quiet delay
   as proof, and do not touch an unrelated service's schedule.
3. **Execute through the existing owners.** Apply only the selected reviewed plan; bind submission
   to its converged job configuration. Persist request intent, dispatch a migration once, then require
   its exact successful evidence before rollout. Cloud Deploy owns deployment/verification/traffic;
   approval and advancement stay within this operation's exclusion. Unknown outcomes stop progression.
4. **Record and finish.** Verify the exact candidate and stable phases, publish the immutable recovery
   receipt, then restore the intended compatible schedule state. Publish immutable operation-completion
   evidence binding the guard generation to the settled native work and receipt. Only then release
   that generation. A missing receipt is repaired from evidence, not by rerunning deployment.

Failure or cancellation uses the same completion boundary, not a success-only unlock shortcut.
Completion evidence must distinguish success, no mutation dispatched, and a reconciled failure.
It identifies the final serving/configuration state, settled operation-owned and pre-pause executions,
and intended schedule state. Pending approvals or ambiguous operation dispatches cannot be treated as
settled. Compatible periodic work may resume at step 4; it is not unfinished deployment work. A migration
failure may need service-maintainer intervention; neither retry nor data rollback is automatic.

## Interruption decisions

| Observation                                                       | Safe next action                                                                          | Guard                                    |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------- |
| Another operation already owns the service                        | Report its identity and reconciliation path; do not mutate.                               | Retained by its owner.                   |
| Runner lost, timed out, or dispatch acknowledgement lost          | Inspect the same stored intent and native operation; do not infer failure or replay.      | Retained.                                |
| Approval/advancement pending or verification failed               | Report the exact rollout and required action; keep automatic advancement/repair disabled. | Retained.                                |
| Deployment healthy, receipt or schedule reconciliation incomplete | Repair only the missing evidence/control step after reconciling its outcome.              | Retained.                                |
| Known failure safely reconciled, or no mutation was dispatched    | Record the terminal outcome and final state; no automatic database restore.               | Release exact generation after evidence. |
| Completion recorded but guard deletion acknowledgement lost       | Read the guard generation and completion record; never remove a successor's guard.        | Reconcile exact generation only.         |

Observation-only commands and narrowly scoped evidence publication must remain available while a
writer is blocked. Do not put the observer behind the writer's concurrency group.

Protected recovery is a separately approved way to finish the recorded operation under its held
guard, not automatic adoption by another runner. It must establish that the previous writer cannot
issue more requests and reconcile accepted cloud work before further mutations. Record its settled
outcome before releasing the guard or admitting a new operation. Cancelling a runner alone is
insufficient: credentials, delayed requests and executable
pending rollouts matter. If their status cannot be established, keep the service blocked. Never
force-unlock merely because a run is old or a health check currently passes.

## Enrollment before activation

- Enroll **every writer**, not just the submission CLI: foundation and job bootstrap/update,
  database maintenance, migration, manual rollout progression, schedule control and receipt completion.
  Retain global infrastructure serialization until shared operations can acquire all affected service
  guards in a stable order, without mutating under a partial acquisition. Do not partially activate
  per-service concurrency beside an unenrolled legacy writer.
- Review narrow guard permissions for maintenance/recovery principals; existing foundation authority
  does not imply access to service release state. Keep the guard out of the locked-retention receipt
  bucket. Exclude it from artifact lifecycle cleanup. Teach the existing
  [state inventory](../internal/inspection/services.go) its exact identity and blocked meaning rather
  than ignoring arbitrary unexpected objects or backend locks.
- Transfer operational ownership of the scheduler's `paused` field explicitly. The current
  [foundation configuration](../modules/service-job-access/rotation.tf) declares it `true`; a future
  foundation apply must not silently undo runtime policy. Prove accepted-request draining and preserve
  safe bootstrap ordering before any resume authority is enabled.
- Bind complete configuration/provenance, durable receipts and effective IAM in one protected caller.
  The service release federation currently permits the exact `release.yaml` workflow; splitting
  workflows requires a reviewed identity change, not just a new filename.
- Keep first launch and state ownership transfer separate from routine release. Remove the old API
  specification/traffic writer only after its native replacement and recovery evidence are proven.

## Implementation and retirement gates

Deliver admission and completion with all participating callers, not another standalone helper that
leaves safety to undocumented callers. Keep native SDK waiting and Cloud Deploy recovery; test the
small decision boundary with table cases for competing owners, lost acknowledgements, ambiguous
execution, missing receipts and stale-generation cleanup. Do not recreate a fake cloud in unit tests.

Then connect one inactive, end-to-end JSON Keys workflow for review, with no live activation implied.
A separately approved interruption/cutover drill must prove service isolation, scheduler draining,
credential boundaries, operator recovery and receipt repair. Only that evidence permits replacing
the corresponding legacy orchestration and its tests. Peer deployments and Renovate remain unchanged.
