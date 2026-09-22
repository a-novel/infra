# Cloud Run rollout boundary (inactive pilot)

This module declares one Cloud Deploy delivery pipeline, its Cloud Run target and probe, execution
identities, private artifact storage, and native operations alerts for one service project.
**No production root calls it. The pipeline is suspended in code**, not behind an input
switch. It cannot deploy an API until a separately reviewed activation change completes the gates
below. The existing production release path remains the only active writer.

The maintainer approved this code-only pilot in [#183](https://github.com/a-novel/infra/issues/183).
[#240](https://github.com/a-novel/infra/issues/240) introduced the boundary;
[#242](https://github.com/a-novel/infra/issues/242) adds the
[JSON Keys manifest and private verifier](../../deploy/cloud-deploy/json-keys/README.md).
The source publisher and submission commands are code-only too. Publication, production wiring,
provisioning and live proof remain separate work.

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

`RENDER`/`DEPLOY` uses the module-owned `rollout-deploy` account, `VERIFY` uses `rollout-verify`,
and the secret-free probe job uses `rollout-probe`. None falls back to the default Compute account.
Executions have a ten-minute limit and a service-specific artifact prefix. The module declares no
APIs, application service, application runtime identity, release, or production workflow.

## Execution authority and storage

The existing [service release identity](../workload-project/README.md),
`infra-release@PROJECT.iam.gserviceaccount.com`, submits releases. `runtime_service_account` is the
separately owned application identity. This module adds only the following grants:

| Identity                          | Granted authority                                                                                                                                                                                                                           |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Submitter                         | Create/read native releases and rollouts, inspect their records, attach deploy/verify accounts. No approve, advance, retry, ignore, cancel, rollback or pipeline-update permission.                                                         |
| Deploy                            | Render and update API specifications/traffic in this service project; attach only the selected app runtime. Read app images and source, create/read artifacts, write execution logs. No job execution or IAM changes.                       |
| Verify                            | Read Cloud Deploy and Run evidence; execute **the exact probe job** with overrides and wait for its operation. Read verifier images, create/read artifacts and write logs. No API/job updates, migration execution or direct secret access. |
| Probe                             | `run.routes.invoke` in this service project. No job execution, database, secret or storage grants.                                                                                                                                          |
| Google Cloud Deploy service agent | Read the selected service's source folder in the management bucket. Its identity and Google-managed project role belong to `workload-project`.                                                                                              |

The [predefined Cloud Deploy roles](https://docs.cloud.google.com/deploy/docs/iam-roles-permissions)
mix submission with operational recovery powers; Cloud Run Developer also permits job execution.
Small custom permission sets keep those responsibilities separate. Standard service-account,
repository-reader and storage roles are bound to the exact resources where they fit. The runner's
storage permissions are bucket-scoped, not granted through a project-wide runner role.

API deployment and invocation are **project-wide**, deliberately relying on one workload per project.
They are not narrowed to a service name by a purported Cloud Run `resource.name` IAM condition.
The reviewed manifest and verifier additionally enforce the expected service. The deployer can run
code as the application identity: `actAs` therefore gives indirect access to that application's
permissions. Source review, the protected target and image provenance remain essential.

`artifact_bucket` names a new private bucket owned by this module in the service project. It uses
uniform access, public-access prevention, versioning and seven-day soft delete. Execution workers
may create/read objects, not overwrite/delete them. There is no age-based expiry: retained releases
must keep their render/rollout artifacts until an explicitly reviewed retirement.

`receipt_bucket` is the existing management bucket. The module owns only its nested
`services/PROJECT/production/sources/` managed folder, with read-only access for render/deploy and
the selected project's Cloud Deploy agent. The parent and the submitter's create/read access remain
owned by `workload-project`; workers get no sibling intent/receipt access. Bucket, folder and identity
deletion are protected. These additive grants do not remove inherited permissions: inspect effective
IAM and test denied peer, secret, receipt-write and non-probe job access before activation.

## Required verifier contract

`verification_image` is a required digest-pinned container in the selected project's regional
Artifact Registry. Its own entrypoint is the verifier; the module injects no shell or command text.
[`cmd/rollout-verifier`](../../cmd/rollout-verifier) implements the verifier and its private probe.
The [artifact publication workflow](../../docs/runbooks/publish-rollout-verifier.md) builds and scans
the image; publication requires a separate opt-in and approval. Verified provenance and promotion
into the selected project's registry remain activation prerequisites. A dummy successful container
would defeat the gate.

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
2. Provision this module only through a separately approved foundation change, after the
   [service-project foundation](../workload-project/README.md) establishes its APIs, Google agents
   and their roles, release identity and management receipt folder. The caller must order this module
   after that foundation and its host subnet grants. The separately composed
   [service foundation](../service-foundation) supplies `agora-production`/`agora-tooling`, the
   application runtime and operations channel. Promote and verify the reviewed verifier digest before
   creating the probe; application release has no writer grant on `agora-tooling`. The
   foundation needs resource/IAM administration and permission to attach the probe identity.
   Verify the host-owned Shared VPC grants and API-only probe egress; test private
   routing, effective IAM, platform-log routing and notification delivery. Target approval,
   advancement/recovery and migration authority remain separate from these execution grants.
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
