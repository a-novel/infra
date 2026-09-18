# Cloud Run rollout boundary (inactive pilot)

This module declares one Cloud Deploy delivery pipeline, its Cloud Run target and probe, and native
operations alerts for one service project. **No production root calls it. The pipeline is suspended in code**, not behind an input
switch. It cannot deploy an API until a separately reviewed activation change completes the gates
below. The existing production release path remains the only active writer.

The maintainer approved this code-only pilot in [#183](https://github.com/a-novel/infra/issues/183).
[#240](https://github.com/a-novel/infra/issues/240) introduced the boundary;
[#242](https://github.com/a-novel/infra/issues/242) adds the
[JSON Keys manifest and private verifier](../../deploy/cloud-deploy/json-keys/README.md).
Artifact publication, submission workflow, IAM provisioning and live proof remain separate work.

`notification_channels` must contain existing operations channels in this service project.
The [native alert runbook](../../docs/runbooks/observe-rollout.md#native-operations-alerts) covers
failure, interruption, approval and advancement events, delivery limits and activation checks.
Cloud Monitoring owns notification delivery independently of GitHub; no custom watcher is required.

## One owner per responsibility

| Owner after the approved handoff         | Responsibility                                                                                                                             |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Protected OpenTofu foundation            | Project, APIs, IAM, network, database hosts, private artifact storage, this pipeline and target.                                           |
| Service-specific OpenTofu release        | Supporting jobs and schedules; no Cloud Run API service resource or traffic writer.                                                        |
| Cloud Deploy + reviewed service manifest | The complete API service specification, revisions, tagged candidate, traffic, verification phases, and rollout records.                    |
| Selected-service release submission      | Complete image-family/provenance checks, explicit database/migration prerequisites, immutable release identity, durable recovery evidence. |
| Human-approved bootstrap/recovery        | Initial deployment, uncertain migration reconciliation, data restore, and exceptional ownership changes.                                   |

Cloud Deploy takes over **the service specification as well as traffic**. Keeping a service resource
in OpenTofu and merely ignoring its traffic field would still leave two competing specification
writers. The raw Cloud Run manifest omits `traffic`; use native Skaffold image substitution
and Cloud Deploy parameters for non-secret coordinates, not another bespoke renderer.

## Rollout policy

For an established service, the native canary strategy starts at zero percent using the `candidate`
tag. Verification must succeed before an operator advances to the built-in `stable` phase, which
serves 100% and runs verification again using the `stable` tag. Target approval is required. There
are no automatic advance/repair resources, pre/post-deployment hooks, or migration tasks here.

The [first deployment can skip the canary](https://docs.cloud.google.com/deploy/docs/deployment-strategies/canary/cloud-run#skipped_phases).
Bootstrap therefore needs separate approval and evidence; this configuration alone is not a
zero-traffic first-launch guarantee. Routine submission must require a known compatible predecessor.

The two execution accounts are explicit, distinct, and in the service project. `RENDER`/`DEPLOY`
cannot silently fall back to the default Compute account, and `VERIFY` does not use the deploy
account. Executions have a ten-minute limit and a service-specific artifact prefix. This module
grants no permissions and creates no identities, buckets, APIs, application workloads, or releases.
It declares one secret-free probe job with a third, distinct runtime identity.
Name validation does not prove bucket privacy, effective IAM, or artifact provenance.

## Required verifier contract

`verification_image` is a required digest-pinned container in the selected project's regional
Artifact Registry. Its own entrypoint is the verifier; the module injects no shell or command text.
[`cmd/rollout-verifier`](../../cmd/rollout-verifier) implements the verifier and its private probe.
The image is **not published by this slice**; reviewed provenance and a promoted digest remain
activation prerequisites. A dummy successful container would defeat the gate.

The verifier must:

- Compare platform-provided `CLOUD_RUN_PROJECT`, `CLOUD_RUN_LOCATION`, and `CLOUD_RUN_SERVICE` with
  the fixed `EXPECTED_PROJECT_ID`, `EXPECTED_REGION`, and `EXPECTED_SERVICE` values in this module.
  A Cloud Run target identifies a project/region, not an allowed service name; IAM and the reviewed
  release manifest must also enforce scope before deployment, not only detect it afterwards.
- Bind `CLOUD_RUN_REVISION` and `CLOUD_DEPLOY_PHASE` to the exact rollout/release/job-run identity.
  At zero percent, resolve the candidate tag to that revision and image. At stable, prove the same
  revision receives 100% and verify the serving endpoint. Never accept the old healthy revision,
  a stale tag, or an unrelated successful execution as evidence for this release.
- Check the service's application health, including dependency status, with bounded time/output and
  a nonzero exit on failure. Emit payload-free evidence, never tokens or response bodies containing
  private data. Verification may be retried, so it must not mutate application state.

[Cloud Run verification runs in Cloud Build](https://docs.cloud.google.com/deploy/docs/verify-deployment),
not in the service's VPC. The bridge is an exact private Cloud Run probe job with an
invoker-only runtime identity and an explicit execution record. It must not reuse the existing
JSON Keys smoke job's secret-reading application identity. Local tests cover execution overrides and
revision binding. Effective permissions, network reachability, and denied peer/secret access need
live proof. Adding a private build pool instead would be a separate cost/network decision.

## Failure ownership

| Interruption                                 | Required behavior                                                                                                                                              |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GitHub runner lost after accepted submission | Inspect Cloud Deploy's existing release/rollout; do not submit another release or restart the whole legacy driver.                                             |
| Release-create response lost                 | Reconcile the predetermined release ID and supported request ID. Persist intent before dispatch and the server operation ID when returned.                     |
| Migration outcome uncertain                  | Stop and reconcile the exact Cloud Run execution. Job execution has no caller request-ID field; a failed client response does not authorize another migration. |
| Candidate verification fails                 | Do not advance. Inspect the failed phase; ordinary traffic remains on the compatible predecessor.                                                              |
| Stable verification fails                    | Treat this as a failure after promotion. Inspect actual traffic and explicitly roll back a compatible release; no automatic repair is enabled in the pilot.    |
| Rollout healthy but receipt missing          | Finish/reconcile durable evidence without blindly redeploying or replaying migrations. Do not report the release complete yet.                                 |

[Cancellation](https://docs.cloud.google.com/deploy/docs/deployment-strategies/manage-rollout)
does not promise to undo completed traffic changes.
[Rollback](https://docs.cloud.google.com/deploy/docs/roll-back) creates a new rollout of a previous
release; it is not an instantaneous revision switch and never restores database contents.
[Hooks must be idempotent](https://docs.cloud.google.com/deploy/docs/hooks), which is why migrations
stay outside them. [#189](https://github.com/a-novel/infra/issues/189) owns the interruption drills
and completion-evidence implementation; this table is a contract, not live proof.

## Before activation

1. Review the service manifest and verifier together, starting with JSON Keys. Preserve internal
   ingress, one warm instance, resource limits, immutable images, numeric secret references, and
   private database routing. No peer configuration or credentials may be required to release it.
2. Provision explicit execution/runtime identities, required APIs, protected artifact storage, and
   narrow service-scoped grants through reviewed HCL. Provision and verify the native operations
   channels and platform-log routing. Separate release submission, target approval,
   deployment, verification, and migration execution. The routine identity must not bypass failed
   verification with `ignoreJob` or update the pipeline. Check effective inherited access too.
3. Review saved source/destination state, inventory, and a reversible one-writer handoff under #187.
   These are new service projects: state import alone cannot move existing cross-project workloads.
   Preserve retained backups and receipts; leave unrelated Renovate automation unchanged.
4. Prove same-service serialization across migrations, configuration changes, release submission,
   phase advancement, and receipts. Cloud Deploy's rollout records are not a lock for external jobs.
   Keep the current deployment serialization until the new complete boundary is proven.
5. Obtain separate approval for a live bootstrap/pilot, then exercise candidate/stable failures,
   runner loss, ambiguous dispatch, rollback, and receipt reconciliation. Only a reviewed subsequent
   change may remove suspension and connect a production caller.

## What this replaces, and what it does not

Cloud Deploy is intended to retire API candidate/traffic/compensation branches in
`ops/google-release-driver.sh`, their orchestration in `ops/release-orchestrator.sh`, and the
API rollout-phase transformations in `internal/release/compile.go`. The service ownership split also
removes peer-preservation logic independently of this platform choice. Retire these complete
capabilities and redundant tests when both services are handed off; do not wrap the old driver in hooks.

Database lifecycle, image-family/provenance policy, migration ambiguity, backup compatibility,
human-only initialization, and durable recovery receipts remain necessary. Existing formats stay
supported for retained recovery points. The inactive pilot adds declarative configuration and a
verification adapter; **it removes no active coordinator yet** and makes no net-size-reduction claim.

The existing foundation test job runs provider-mocked cases for this standalone module, using the
root's pinned provider. Go tests cover the safety contract and exercise the official clients against
a local HTTP server. CI also checks formatting and lint. No tests contact Google Cloud; they establish
configuration and input boundaries, not live IAM, probe routing, or rollout behavior.

Google's current [pricing](https://cloud.google.com/deploy/pricing) has no management fee for a
single-target pipeline. Cloud Build, storage, logs, and application resources remain billable.
References were checked on 18 September 2026 against the repository's Google provider 8.2.0:
[pipeline](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/clouddeploy_delivery_pipeline),
[target](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/clouddeploy_target),
[release request identity](https://docs.cloud.google.com/deploy/docs/api/reference/rest/v1/projects.locations.deliveryPipelines.releases/create),
[Cloud Run Jobs execution](https://docs.cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs/run),
and [native deployment parameters](https://docs.cloud.google.com/deploy/docs/parameters).
