# JSON Keys private verification pilot

**Code only.** No production root calls the [rollout module](../../../modules/cloud-run-rollout),
and its pipeline stays suspended. Do not apply this service manifest directly: Cloud Deploy must
own both its specification and traffic after the separately reviewed one-writer handoff.

## Native release inputs

`skaffold.yaml` renders `service.yaml` without builds or hooks. The [render-only submitter](../../../docs/runbooks/submit-release.md) accepts exactly
one `buildArtifacts` entry named `service-json-keys`, pointing to the promoted API digest in
`REGION-docker.pkg.dev/PROJECT/agora-production/service-json-keys/grpc@sha256:…`.
Complete image-family and provenance checks still precede submission; verification does not replace them.
Its private create-only intent prevents redispatch of the same release identity after interruption.
The [rollout handoff](../../../docs/runbooks/submit-release.md#submit-the-approval-gated-rollout)
reserves one approval-gated rollout for that release and reconciles it read-only after interruption.
There is no production caller yet: trusted packaging, parameter authorization, service locking,
bootstrap/predecessor checks and the final success receipt remain activation gates.

[Cloud Deploy parameters](https://docs.cloud.google.com/deploy/docs/parameters) replace the marked
fields without a custom renderer:

| Parameter                                     | Source / constraint                                                    |
| --------------------------------------------- | ---------------------------------------------------------------------- |
| `projectId`, `network`, `subnetwork`          | Selected service project's reviewed foundation coordinates.            |
| `runtimeServiceAccount`                       | JSON Keys application identity, never the probe or deployment account. |
| `databasePrivateIP`                           | Only this service's database host.                                     |
| `managementProjectNumber`                     | Secret-owning management project number.                               |
| `masterKeyVersion`, `postgresPasswordVersion` | Verified enabled positive numeric versions; never `latest`.            |

Unset defaults are deliberately unusable. The submission boundary must validate parameters against
the selected foundation and pinned secret metadata before creating a release. No secret payload is
an input to Cloud Deploy. The manifest retains internal ingress, IAM authentication, one warm instance,
three maximum instances, 1 CPU / 512 MiB, h2c, private database routing and the current connection limits.

## Verification path

1. Cloud Deploy runs `rollout-verifier` in Cloud Build. The official Go clients read the exact release,
   rollout, verification job run, service and revision. The checks require the promoted release image,
   ready private service and phase traffic: candidate tag at 0%, or selected revision at 100% for stable.
2. The verifier checks the reviewed probe job, then calls `RunJob` once with its current etag and one
   payload-free `VERIFY_REQUEST` override. The request binds the endpoint, audience, phase, revision,
   image and Cloud Deploy job run. It prints the returned operation ID before waiting through the SDK.
3. The job runs the same binary as `rollout-verifier probe`, with a separate invocation-only identity.
   An official ID-token source authenticates to the service audience. Candidate checks use the tagged
   endpoint; stable checks use the ordinary serving endpoint. The dependency-aware
   `/anovel.jsonkeys.v2.StatusService/Status` RPC must succeed within 30 seconds. A TCP connection or
   Cloud Run readiness condition is not application-health evidence.
4. Only this invocation's successful, single-attempt execution with the exact template and request
   is accepted. The verifier rechecks the control plane, then prints revision/image/job-run/execution
   identifiers. Tokens, secret values and response bodies are never logged.

The probe timeout is 90 seconds, the verifier bound is eight minutes and the platform execution limit
is ten minutes. An uncertain dispatch or interrupted wait fails verification and tells the operator
to reconcile the recorded operation/execution before retrying. There is no list-and-pick-latest lookup,
resubmission, migration, traffic change, automatic rollback, or production receipt publication here.
Stable failure occurs **after** promotion; it does not claim the predecessor still serves traffic.

## Identity, network and artifact prerequisites

The module declares one [Cloud Run job](https://registry.terraform.io/providers/hashicorp/google/8.2.0/docs/resources/cloud_run_v2_job),
not another long-running service. It scales to zero between probes and uses 1 CPU / 256 MiB per task.
It has no durable data, env credentials or volumes. Deletion is guarded; recreation from the reviewed
definition is its recovery path. Verification incurs ordinary job/build/log usage when executed.

| Identity | Required boundary before activation                                                                                                                                                                                                             |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Deploy   | Own-service deployment plus approved runtime impersonation; no probe execution or migrations.                                                                                                                                                   |
| Verify   | Cloud Deploy record reads, Run service/revision reads, and `run.jobs.get`, `run.jobs.run`, `run.jobs.runWithOverrides`, `run.operations.get` for the probe/operation. No job updates, phase advancement, ignore-job authority or secret access. |
| Probe    | Invocation of this service only. No database, Secret Manager, artifact-write or peer-service grants.                                                                                                                                            |

Grants must be scoped at the narrowest supported resource boundary and checked for inherited access.
The network/subnet pair comes from the foundation-owned Shared VPC host, not a duplicate service VPC.
The dedicated `agora-rollout-probe` network tag needs only restricted Google API HTTPS egress and the
matching private DNS/Google Access path; it must not inherit the application's PostgreSQL allowance.
This slice **does not provision** those identities, grants, firewall rules or APIs.

`builds/rollout-verifier.Dockerfile` builds one unprivileged image from the reviewed Go module. Local
`a-novel build --type=podman -y` does not publish it. Publication must attest the exact source, scan the
image, promote it into the service project's registry and pin the same digest in the worker and probe.
Dependency downloads belong in that unprivileged build, never in a credentialed verification task.

Before activation, prove actual SDK resource-name/image/network normalization, candidate/stable routing,
negative IAM/network cases and interruption handling in the approved pilot. Keep same-service release
serialization through the probe and receipt, since reading before/after is not a distributed lock.
[#189](https://github.com/a-novel/infra/issues/189) retains the GitHub Actions completion-tracking contract:
observe exact rollout/verification outcomes and durable receipt completion, not merely submission.
The [read-only observer](../../../docs/runbooks/observe-rollout.md) and repo-local action report those
native outcomes. No production workflow calls them. The rollout module also declares
[native operations alerts](../../../docs/runbooks/observe-rollout.md#native-operations-alerts);
live notification delivery, receipt integration and interruption proof remain activation prerequisites.
