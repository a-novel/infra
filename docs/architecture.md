# Infrastructure architecture

This document explains the operating model behind Agora's infrastructure. It records the cloud and
delivery concepts a contributor needs in addition to OpenTofu syntax. Google Cloud product behavior
and the network contract live in the [Google Cloud provider guide](./google-cloud.md).

## Design basis

Agora uses a small landing-zone architecture. A landing zone establishes the state, identity,
network, recovery, and governance boundaries that application infrastructure consumes. Google's
[enterprise foundations blueprint](https://cloud.google.com/architecture/blueprints/security-foundations)
uses the same layered idea at organization scale, and its
[deployment methodology](https://cloud.google.com/architecture/blueprints/security-foundations/deployment-methodology)
separates foundation, infrastructure, and application pipelines.

This repository keeps the parts that reduce risk for a small team and leaves out the enterprise
fleet. It has one production environment, two projects, three state roots, and no permanent staging,
central policy engine, organization hierarchy, shared-VPC fleet, or Kubernetes control plane.

| Principle                                | How this repository applies it                                                                                   | Primary reference                                                                                                                              |
| ---------------------------------------- | ---------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Layered cloud foundation                 | Bootstrap, durable foundation, and routine release changes have separate roots and identities.                   | [Google Cloud foundation deployment methodology](https://cloud.google.com/architecture/blueprints/security-foundations/deployment-methodology) |
| Small state and lifecycle boundaries     | Each root has an independent backend object, lock, provider lock file, and change cadence.                       | [Google root-module practices](https://cloud.google.com/docs/terraform/best-practices/root-modules)                                            |
| Least privilege and separation of duties | Each automation identity receives authority only for its root; workload identities are dedicated per use case.   | [Google service-account practices](https://cloud.google.com/iam/docs/best-practices-service-accounts)                                          |
| Reviewed execution                       | A protected apply uses the saved plan that an operator reviewed.                                                 | [Google infrastructure operation practices](https://cloud.google.com/docs/terraform/best-practices/operations)                                 |
| Flat composition                         | Resources stay in their root until reuse or one shared security invariant justifies a module.                    | [OpenTofu module composition](https://opentofu.org/docs/language/modules/develop/composition/)                                                 |
| Versioned desired state                  | Infrastructure and release inputs are declarative, reviewed, and retained in Git history.                        | [OpenGitOps principles](https://opengitops.dev/)                                                                                               |
| Immutable application artifacts          | Releases identify OCI images by digest and verify hosted-build provenance before deployment.                     | [OCI image specification](https://specs.opencontainers.org/image-spec/) and [SLSA provenance](https://slsa.dev/spec/v1.2/provenance)           |
| Defense in depth                         | Network reachability, workload identity, IAM, protected automation, and recovery controls reinforce one another. | [Google security-by-design guidance](https://cloud.google.com/architecture/framework/security/implement-security-by-design)                    |

The repository follows the declarative and versioned OpenGitOps principles today. A later merge
workflow will apply accepted desired state and scheduled drift checks will detect divergence. This is
a GitOps-style delivery model, not strict OpenGitOps conformance: no continuously pulling controller
currently reconciles the platform.

## Vocabulary

| Term                 | Meaning here                                                                                                     |
| -------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Management project   | Stable recovery plane that holds state, federation, secret payloads, logical backups, and release receipts.      |
| Workload project     | Replaceable production plane that holds the VPC, compute, services, operational storage, logs, and monitoring.   |
| Root                 | Independently initialized OpenTofu working directory with its own state and automation authority.                |
| Foundation           | Long-lived infrastructure that survives an ordinary application release.                                         |
| Release              | Routine application state such as images, revisions, jobs, traffic, and database container configuration.        |
| Ingress              | Connections accepted by a workload.                                                                              |
| Egress               | Connections initiated by a workload. Ingress and egress are independent controls.                                |
| Application rollback | Restoration of the prior release receipt while backward-compatible schema changes remain.                        |
| Data restore         | Approved replacement of database contents from a named backup or snapshot, with an explicit lost-write boundary. |

## Root ownership

```text
bootstrap                         production foundation                   production release
stable recovery authority   ->   durable workload authority       ->     routine deployment authority
rare changes                     occasional changes                      frequent changes
```

| Root                                                                            | Owns                                                                                                                                          | Authority boundary                                                                                                                                  |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`bootstrap/`](../bootstrap/)                                                   | Resources inside the manually created management project: state and recovery storage, federation, automation identities, and secret metadata. | May establish later automation identities. It does not create its own project or deploy application revisions.                                      |
| [`environments/production/foundation/`](../environments/production/foundation/) | Workload project, IAM, VPC, private data plane, database host and disks, backups, monitoring, and stable runtime prerequisites.               | May change durable infrastructure after protected human approval. It does not select routine application versions.                                  |
| [`environments/production/release/`](../environments/production/release/)       | Container images, jobs, revisions, traffic, and database container configuration described by the release manifest.                           | May deploy and compensate an application release. It cannot change project IAM, networking, state protection, preserved disks, or backup retention. |

The roots apply in that order. A root consumes only the small set of outputs it needs from an earlier
root and never embeds another root's credentials or state. The foundation automation identity is the
deliberate high-trust exception to state isolation: after the human bootstrap, its protected workflow
maintains both `bootstrap` and `foundation`. Release remains confined to its own state, while recovery
can restore all three state roots without receiving IAM-administration authority.

## Stateful database ownership

The PostgreSQL host follows the stable infrastructure, mutable configuration pattern. Foundation
owns everything whose accidental loss can destroy data or network identity: the balanced data disk,
instance template, one-member stateful managed instance group, preserved private address, machine
shape, startup code, firewall, IAM, and capacity alerts. A foundation apply creates the host in an
idle state when no release metadata exists.

Foundation seeds one group-level `allInstancesConfig` map containing an empty Git commit, two empty
image references, and four zero owner/backup password-version identifiers. It ignores later drift
only on that nested map. The protected release workflow derives all seven non-secret values from
reviewed inputs and calls the tested
[`deploy-database-release.sh`](../ops/deploy-database-release.sh) helper. The helper validates the
exact project, repositories, digests, commit, zone, and positive version identifiers, then reads the
existing map and requires exactly those seven keys. Before mutation, its shared recovery gate also
requires a ready scheduled snapshot no older than six hours and—except for an empty first
release—fresh logical backups of both databases. Only after those fail-closed checks does it invoke
Google's supported all-instances update and apply it to the sole member with both the minimum and
maximum action set to `RESTART`.

The MIG update policy is `OPPORTUNISTIC`, so changing group metadata or a foundation template cannot
act on the live member before the owning protected workflow states its disruption ceiling. Routine
release uses `RESTART`; reviewed foundation maintenance uses `REPLACE` and `RECREATE`. The group has
zero surge, so both are short single-host outages and neither creates a second disk writer.

This small imperative edge is deliberate. The Google provider's
[`google_compute_per_instance_config` create path](https://github.com/hashicorp/terraform-provider-google/blob/v7.45.0/google/services/compute/resource_compute_per_instance_config.go)
calls `createInstances`; it creates a new MIG member and cannot safely adopt the existing
foundation-owned member. Duplicating the MIG resource across two OpenTofu states would create
overlapping ownership. Keeping the fixed command in versioned, tested code preserves one owner for
the durable resource while the release identity remains limited to group-manager read/update,
zonal-operation polling, snapshot-metadata listing, and the `setMetadata` permission Google requires
for an existing VM. It cannot create or delete snapshots. An IAM condition fences the sole VM
permission to generated `agora-database-*` members. The protected workflow and receipt are introduced
by the deployment task; until then the helper has no authenticated caller.

```text
foundation template + stateful disk/address + MIG
                         |
                         v
              one generated VM
                         ^
                         |
tested group metadata update, capped at RESTART
                         ^
                         |
release commit + image digests + secret version IDs
```

This split gives ordinary deployments enough authority to converge both database containers and no
disk, template, network, IAM, secret-payload, or direct instance-lifecycle permission. Google's
group-manager update permission is coarser than the seven-field operation and can affect group
lifecycle indirectly, so the fixed helper, resource-name condition, protected environment,
committed manifest, audit log, health gate, and private receipt form the remaining controls. A
compute rollback restores the prior foundation template. An application rollback runs the same
helper with the prior receipt. Neither rollback rewinds schema or data; that remains a separately
approved restore.

## Database recovery layers

Recovery uses two complementary layers and no always-running backup controller:

```text
private PostgreSQL clusters
      |                          preserved data disk
      | pg_dump every 4h               | daily 02:00 UTC
      v                                v
create-only logical objects       crash-consistent snapshots
      |                                |
      v                                |
management-project bucket              |
      |                                |
      | read-only                      |
      v                                v
fresh local restore drill       approved disk recovery only
```

Logical backups are portable and independently tested. Each backup uses the exact promoted database
image, verifies that digest and PostgreSQL major against the running source, uses a restricted
read-only PostgreSQL role and a unique object path, and uploads a manifest only
after non-empty, archive-list, size, and checksum validation. The backup identity can create objects
but cannot discover, read, overwrite, or delete them. The restore identity can read objects but has
no database route, no secret, and no write permission. It restores into an ephemeral local-only
cluster and runs service-specific integrity checks. An hourly job turns missing/stale manifests,
RPO, object-size, and storage-cost violations into the same native Cloud Run completion-metric alert
as a backup or restore failure. A metric-absence condition also reports when that hourly monitor has
not completed for three hours.

The bootstrap bucket retains every object for at least seven days and deletes it after 14 days. Its
retention lock is deliberately enabled only through a reviewed irreversible code change after the
first clean restore evidence. Globally scoped daily snapshots store their data in `europe-west1`,
retain seven days while the source disk exists, and survive source-disk deletion; they are fast
same-region crash-consistent recovery points, while the EU multi-region logical objects provide the
regional-loss path and tested `pg_restore` evidence.

The launch contract accepts one correlated Google Cloud failure domain. The management project
separates routine workload authority, but an organization- or provider-wide compromise can still
affect every recovery copy. A second provider adds credentials, billing, transfer, testing, and
incident ownership; introduce it when revenue, compliance, or recovery commitments justify that
operating cost.

The [PostgreSQL recovery runbook](./runbooks/backup-and-restore-postgresql.md) owns first activation,
retention locking, monthly RTO measurement, alert response, the one-time cross-project drill, and
the measured thresholds that trigger a PITR design.

## State and bootstrap

The Google Cloud Storage backend bucket must exist before OpenTofu can use it. The initial bootstrap
therefore starts with temporary local state under an operator's control, creates and verifies the
management state bucket, migrates that state to the backend, and removes the temporary broad
authority. The [bootstrap runbook](./runbooks/bootstrap-management-plane.md) provides the exact
operator commands, safe expected output, independent checks, partial-failure response, and cleanup.

Each root uses a distinct managed-folder state prefix and a distinct automation identity. Writer
identities use GCS backend locking. Read-only drift jobs use root-scoped workflow serialization and
plan without a backend lock, so they never receive state-write permission. Object Versioning and soft
delete supply recovery from an accidental overwrite or deletion. State is private recovery data: it
never enters Git, GitHub artifacts, pull-request comments, or public logs. OpenTofu manages secret
containers and access policies, while operators add secret payload versions through stdin outside
OpenTofu so payloads do not enter state. The
[state recovery runbook](./runbooks/state-recovery.md) restores an exact generation with an atomic
precondition and can restore the former live generation if validation fails.

The [OpenTofu GCS backend documentation](https://opentofu.org/docs/language/settings/backends/gcs/)
defines the backend's locking and versioning requirements. The provider guide documents Agora's
Google Cloud controls around that backend.

## Change lifecycle

```text
branch or Renovate PR
        |
        v
cloud-blind validation and security checks
        |
        v
human review and coordinated merge gate
        |
        v
protected plan and approval        (introduced by later tasks)
        |
        v
apply the exact reviewed plan
        |
        v
convergence, health, receipt, and drift checks
```

Pull requests validate structure, mocked behavior, policy fixtures, manifests, and workflow security.
They receive no Google identity and cannot read a backend. A protected workflow will later plan from
the reviewed commit, store an opaque plan outside GitHub, expose only sanitized action counts, and
apply that exact plan after its required approval. Foundation and release identities remain separate.

A release failure restores the prior application receipt. Database migrations remain because service
policy requires backward-compatible changes. Restoring database contents is a recovery operation with
its own approval and runbook.

## Portability boundary

Agora standardizes the application boundary rather than maintaining two infrastructure
implementations. Applications remain OCI images and communicate through HTTP, gRPC, PostgreSQL, SMTP,
environment configuration, health endpoints, and graceful termination. Google Cloud networking, IAM,
storage, and managed runtime behavior stay explicit in the provider guide and OpenTofu resources.

Kubernetes becomes useful when Agora has a workload Cloud Run cannot support, commits to a second
runtime, needs a Kubernetes operator, or measures a lower total operating cost. Until then, a shadow
Kubernetes representation would add another security and upgrade surface without improving recovery.

## Documentation ownership

The root [README](../README.md) is the operator entry point. This document owns architectural
rationale and lifecycle boundaries. The [Google Cloud provider guide](./google-cloud.md) owns provider
behavior and security contracts. Each root README owns the exact inventory of resources in that root.
Runbooks own commands, expected safe output, verification, and recovery from partial failure.

A resource change updates its root inventory and the relevant runbook in the same pull request. HCL
comments explain only a local invariant that the resource arguments do not make clear; they do not
repeat OpenTofu syntax or paraphrase external provider documentation.
