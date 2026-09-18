# Persist and reconcile a native release submission

**Code-only JSON Keys pilot. No production workflow calls these commands.** Live use still needs
the [activation gates](#before-live-use); do not grant permissions or replace the existing release
workflow just to try them.

This adapter owns one handoff: preserve the exact request, then ask Cloud Deploy to create and render
that release. Google's clients own authentication, API decoding and operation waiting. Cloud Deploy
owns rendering; this adapter has no rollout, migration, traffic, rollback or deletion operation.

## The private request

The trusted caller supplies the service project ID, numeric project number, region and management
receipt bucket **independently** of the request. Their syntax is validated, but their authorization
and project-number relationship must come from the reviewed foundation contract.

The input is Google's native
[`CreateReleaseRequest`](https://docs.cloud.google.com/deploy/docs/api/reference/rest/v1/projects.locations.deliveryPipelines.releases/create)
JSON, limited to 64 KiB. The [test fixture](../../internal/submission/testdata/request.yaml) illustrates
its fields in readable YAML; it is not a production configuration. The future trusted packager must
emit JSON, not run a shell templating pipeline inside a credentialed job.

| Field                                                   | Accepted contract                                                                                                                                                                                                                                              |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `parent`, `releaseId`, `release.name`                   | One predetermined release in the selected numeric project's `agora-json-keys-grpc` pipeline and region.                                                                                                                                                        |
| `requestId`                                             | Nonzero lowercase UUID, chosen once and retained.                                                                                                                                                                                                              |
| `release.annotations`                                   | Exactly `request-id` matching that UUID and `source-commit` containing the reviewed 40-character commit.                                                                                                                                                       |
| `release.skaffoldConfigUri`                             | `gs://BUCKET/services/PROJECT_ID/production/sources/COMMIT.tar.gz`.                                                                                                                                                                                            |
| `release.skaffoldConfigPath`, `release.skaffoldVersion` | `skaffold.yaml` and a reviewed numeric `x.y.z` pin; no floating default.                                                                                                                                                                                       |
| `release.buildArtifacts`                                | Only `service-json-keys`, bound to the selected project's promoted gRPC image digest.                                                                                                                                                                          |
| `release.deployParameters`                              | Exactly the [eight pilot parameters](../../deploy/cloud-deploy/json-keys/README.md#native-release-inputs). The account belongs to this project, network and subnet share a host/region, database IP is private IPv4, and secret versions are positive numbers. |

Unknown fields, output-only fields, policy overrides and `validateOnly` are rejected. No credentials
or secret payloads belong in this record. Parameter syntax does **not** prove enabled secret versions,
image provenance, ownership of the database IP, or the contents/immutability of the source archive.

## Submission contract

After separate live approval and completion of the gates below, the invocation will be:

```sh
infra submit-release \
  --project-id="${SERVICE_PROJECT_ID:?}" --project-number="${SERVICE_PROJECT_NUMBER:?}" \
  --region="${REGION:?}" --receipt-bucket="${RECEIPT_BUCKET:?}" \
  --timeout=10m "${PRIVATE_REQUEST_FILE:?}"
```

Build the reviewed binary before protected inputs or cloud credentials are present. These variables
come from the selected service's reviewed contract, not the legacy shared production project.

The command first creates
`services/PROJECT_ID/production/submissions/RELEASE_ID.json` in the private receipt bucket with
[`ifGenerationMatch=0`](https://docs.cloud.google.com/storage/docs/request-preconditions).
Only an acknowledged, new object permits **one** `CreateRelease` call. An existing object is a stop,
even if its contents match. An uncertain storage response also stops before Cloud Deploy is called.
There is no "read identical bytes, then resend" path.

The returned operation name is stored separately as `RELEASE_ID.operation.json`, also create-only,
before waiting through the official client. Cancellation stops local observation, not the cloud
operation. Neither record is removed on failure. Errors contain fixed diagnostics, not provider
response bodies or request contents.

A zero exit status means a matching release is **rendering or rendered**, not deployed. The command
prints that distinction explicitly. A render failure, abandoned release, conflict, missing evidence
or interrupted operation returns nonzero. No initial rollout is created by this API call.

## Reconcile an interruption

Use the exact release ID printed at submission, with the same independently selected scope:

```sh
infra reconcile-release \
  --project-id="${SERVICE_PROJECT_ID:?}" --project-number="${SERVICE_PROJECT_NUMBER:?}" \
  --region="${REGION:?}" --receipt-bucket="${RECEIPT_BUCKET:?}" \
  "${RELEASE_ID:?}"
```

This path only reads the exact private intent and exact Cloud Deploy release. It compares the
submitted fields, ignoring native timestamps/render results, and reports current rendering state.
It does not list resources, choose the latest release, use the operation record to resend, or write
anything. It remains usable if the create response or operation-record acknowledgement was lost.

| Evidence                             | Action                                                                                                                                       |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Matching release, rendering          | Reconcile the same ID later; do not submit again.                                                                                            |
| Matching release, rendered           | Rendering succeeded. Rollout, verification and final receipt remain separate obligations.                                                    |
| Failed render or abandoned release   | Inspect that release and the native render/build diagnostics; obtain a reviewed recovery decision.                                           |
| Missing or unreadable intent/release | Stop. Inspect private storage, IAM and native audit/operation evidence. A 404 or permission error is not proof that dispatch never happened. |
| Request/identity conflict            | Stop. Resolve the mismatch; do not overwrite records or accept an unrelated release.                                                         |

Google guarantees request-ID deduplication for **at least 60 minutes**, not indefinitely. This adapter
does not use that window as a retry loop: a persisted intent never authorizes a second dispatch.
Do not delete the reservation or invent a new UUID/release ID to recover an uncertain request.
A crash after reserving intent but before dispatch intentionally requires operator reconciliation.

## Before live use

The remaining work in [#189](https://github.com/a-novel/infra/issues/189) and
[#187](https://github.com/a-novel/infra/issues/187) must establish:

- A trusted caller that validates the complete image family/provenance and binds parameters to the
  selected foundation and exact enabled secret metadata.
- Reviewed archive publication with create-only storage and provenance. The source-commit filename
  alone does not prove its contents. Keep source/intent/operation objects private, non-overwritable
  and non-deletable by submitters; lifecycle must not discard them while an identity can be reused.
  Cloud Deploy's renderer needs read access to the exact source prefix, not receipt-write access.
- Same-service exclusion before mutations, including migrations, through rollout and receipt
  completion. A reservation prevents duplicate creation of **one ID**; it is not a service lock.
- A separate exact rollout-create handoff, the existing [native observer](observe-rollout.md),
  final durable recovery receipt, and migration interruption handling. Rendering is not final success.
- Least-privilege identities, the one-writer OpenTofu/Cloud Deploy handoff, and a human-approved
  interruption drill that verifies actual API normalization, IAM and receipt recovery.

No legacy receipt format, workflow, production resource or Renovate setting changes in this slice.
