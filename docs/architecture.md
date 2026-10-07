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
fleet. Production uses a management project and three workload trust zones: private, public-api and
public. JSON Keys and Authentication each keep one database VM in private; API components of the same
service share that database. Public is reserved for platforms and has no private network attachment.
Staging and Kubernetes remain deferred.

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

The repository follows the declarative and versioned OpenGitOps principles today. Protected
workflows apply accepted desired state and a scheduled read-only drift check detects divergence.
This is a GitOps-style delivery model, not strict OpenGitOps conformance: no continuously pulling
controller currently reconciles the platform.

The [service-release root](../environments/service-release) declares API revisions, traffic and jobs
directly in HCL. Its shared API writer remains disabled pending resource ownership handoff. The
[release sequence](./runbooks/submit-release.md) uses native Cloud Run traffic targets and retains
migration, health and private-plan checks. The working production path described below remains
the owner until that handoff is proven.

The maintenance rule is one owner per concern: HCL for resources, protected GitHub Actions for the
sequence, and systemd/pgBackRest for database processes and recovery. Custom code is limited to gaps
those native mechanisms do not cover, such as provenance, private plan custody and uncertain job
outcomes. The [service-operation contract](./service-operations.md) explains those retained boundaries.

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

Production uses five native OpenTofu roots with separate state:

| Root                                                            | Owns                                                                                                    |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| [bootstrap](../bootstrap/)                                      | Management storage, federation, automation identities and secret containers                             |
| [production foundation](../environments/production/foundation/) | Trust-zone projects, private network, per-service database hosts, invocation tags and rotation schedule |
| [service foundation](../environments/service-foundation/)       | Each service/zone's runtime prerequisites, repositories and native-backup resources                     |
| [service release](../environments/service-release/)             | API revisions, traffic and operational jobs                                                             |
| [service recovery](../environments/service-recovery/)           | Explicitly approved isolated recovery resources                                                         |

The protected foundation workflow plans and applies the first four roots. Recovery has its own
protected workflow and identity. The read-only plan identity assesses exact changes without
state-write or secret-payload authority. Roots exchange narrow published coordinates rather than
embedding another root's credentials or entire state.

There is no separate release workflow or per-service deployment federation. Foundation is the
explicit high-trust administrator; its approval boundary, saved plans, service guards and scoped
runtime grants remain essential. Routine service releases cannot resize database hosts.
Cloud Run definition changes and job execution are separate grants. Invocation classes distinguish
migrations, scheduled jobs and internal calls. Authentication initialization remains a named-human
action with its own identity and tag; routine automation cannot read its administrator password.

## Stateful database ownership

Foundation owns one private singleton database VM per service repository, with its immutable
COS template, preserved data disk and address, runtime identity and firewall boundary. APIs
from different trust zones share that repository's database; they do not create duplicate clusters.

Routine application releases do not change database hosts. Database image and startup changes use
the protected foundation workflow and an exact saved plan. It records a private maintenance hold,
verifies a fresh native full backup and isolated SQL restore on the existing repository VM, then
updates only the selected host. Startup replacement uses zero surge and preserves the data disk
and address. Image changes cap disruption at restart and preserve the existing VM and boot disk.
Both require a new healthy boot and exact identity checks before publishing completion evidence.

The groups remain `OPPORTUNISTIC`: changing a template target alone does not roll a member.
OpenTofu owns the durable resources; the small tested maintenance helper handles this deliberate
imperative boundary. It cannot treat a successful plan apply as proof of host adoption, replay a
consumed plan after uncertainty, or clear a hold without matching completion evidence.

There is no legacy release compiler, receipt-driven database deployment, isolation-drill workflow
or logical-backup job prerequisite. Historical receipts remain readable as evidence, not executable
deployment instructions. See [host maintenance](./runbooks/operate-postgresql-host.md) for admission,
recovery and capacity limits.

## Native database recovery

Each database has a private pgBackRest repository host and a separate management-owned bucket.
Native systemd workers and timers run archive checks, weekly full backups and daily differentials;
the database lifecycle controls their activation. PostgreSQL hosts do not receive bucket-write
authority. Mutually authenticated TLS protects the database/repository connection, and repository
identity is scoped to its service's storage.

pgBackRest performs chain-aware expiration under the reviewed retention settings. Bucket retention,
versioning and soft deletion are separate recovery and cost boundaries; they are not a substitute
for verifying a complete restorable chain. Never apply age-only deletion to a live repository.

Protected maintenance restores an exact backup set on existing bounded repository scratch space
and verifies a networkless paused SQL instance. Independently provisioned disaster-recovery
rehearsal, application-data verification, failure notifications and operational cost review have
separate acceptance evidence. A successful scheduled backup alone proves none of those claims.

The removed logical jobs and daily snapshots are not a second active recovery architecture.
Historical objects subject to locked retention must remain until eligible for separately verified
cleanup. Their presence does not authorize keeping old writers or deployment tooling.

The launch contract still accepts a correlated Google Cloud failure domain. Management-project
separation limits workload authority, not organization- or provider-wide compromise. A second
provider requires a separately justified credential, cost and incident-ownership decision.
The [recovery runbook](./runbooks/backup-and-restore-postgresql.md) owns native restoration and
retirement procedures; [acceptance](./runbooks/accept-native-backups.md) owns the evidence checklist.

## Proportionate observability and external SMTP

Foundation uses provider signals for application and database capacity alerts. Each service
foundation owns its bounded native-backup log metric and failure/freshness policies. The existing read-only drift workflow makes one public
`/v2/healthcheck` request every three hours and fails unless Authentication, private JSON Keys,
private PostgreSQL, and hosted SMTP are all healthy. The production release switch gates this
check, and the workflow reads the exact project and region from private configuration rather than
discovering or logging them. Separate operations and cost email channels both receive the
current/forecast budget; only operations receives Google application incidents. Successful request
logs for the two exact health paths are excluded while failures, application logs, and audit records
remain for 30 days. Authentication and JSON Keys export OpenTelemetry traces and logs over OTLP to
Google's Telemetry API with their own runtime identities, so the same instrumentation can move to any
OTLP backend without an agent or collector.

The three-hour cadence is a launch-stage cost and detection tradeoff. Authentication needs
instance-based CPU because detached mail can continue after an HTTP response, and Google may keep
such an instance billable for up to 15 idle minutes after every request. A five- or fifteen-minute
uptime check could therefore keep the service continuously allocated. Eight scheduled wakes per day
bound that exposure to at most roughly 60 instance-hours per 30-day month before organic traffic,
while a public repository's standard GitHub runner has no usage charge. Detection can take three
hours plus GitHub scheduling delay; this is not a page-grade SLO. Move mail to a request-bound or
queued path, or adopt provider-native faster probes, when traffic or on-call requirements justify
that cost.

This avoids a separate observability agent, webhook, Pub/Sub topic, dashboard fleet or controller.
The bounded backup log metric feeds native alert policies without another monitoring process. The
[alert runbook](./runbooks/respond-to-alerts.md) supplies ownership and first bounded checks. Add a
new alerting product only when response coverage or on-call requirements exceed monitored email and
native GitHub workflow notifications.

Authentication mail uses Google Workspace SMTP relay through authenticated STARTTLS. An existing
Workspace account authenticates the connection while an unregistered address in the verified domain
supplies the sender name and email. The operator manages relay access, domain authentication,
account limits, delivery logs, and app-password rotation through the
[SMTP runbook](./runbooks/configure-hosted-smtp.md). Code consumes the standard SMTP host, port,
username, sender fields, and one exact Secret Manager password version. Cloud Run uses managed
public egress for this connection; the relay requires authentication and TLS without an IP allowlist.

## Disposable recovery cleanup

Recovery state and immutable receipts remain in the stable management plane. A clean-room rebuild
creates no duplicate production budget, notification channel, or alert policy. It
receives quota ceilings and bounded logs, and its recovery identity gains the predefined Project
Deleter role only inside that disposable project. Production and management never grant project
deletion.

Cleanup intentionally deletes the project as one unit instead of destroying nested OpenTofu
resources. It requires a committed exact project/receipt tuple, human attestation that all temporary
cross-project secret/bucket access was removed, a deletion label present when that commit's pull
request merged, protected-environment approval, code-owned recovery labels, the exact project-local
deleter binding, and typed confirmation. Nested recovery state and the receipt remain immutable
evidence. This exceptional path minimizes billed drill lifetime without turning routine OpenTofu
into a project-deletion authority.

## State and bootstrap

The Google Cloud Storage backend bucket must exist before OpenTofu can use it. The initial bootstrap
therefore creates the empty private bucket with versioning and soft delete, initializes the backend,
and imports the bucket before the first plan. OpenTofu manages it from that plan onward, and state is
never written to the repository checkout. The
[bootstrap runbook](./runbooks/bootstrap-management-plane.md) provides the exact operator commands,
safe expected output, independent checks, partial-failure response, and cleanup.

Each normal root uses a distinct managed-folder state prefix and a distinct automation identity.
Recovery can read normal state but can write only four nested managed folders under
`foundation/{recovery,plans/recovery}/` and `release/{recovery,plans/recovery}/`; it cannot overwrite
bootstrap or production state. Writer identities use GCS backend locking. Read-only drift jobs use
root-scoped workflow serialization and plan without a backend lock, so they never receive state-write
permission. Object Versioning and soft delete supply recovery from an accidental overwrite or deletion. State is private recovery data: it
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
manual protected plan and approval
        |
        v
apply the exact reviewed plan
        |
        v
convergence, health, receipt, and drift checks
```

Pull requests validate structure, mocked behavior, policy fixtures, manifests, and workflow security.
They receive no Google identity and cannot read a backend. Protected workflows plan from the reviewed
`master` commit, store the opaque plan in private GCS for at most 24 hours, expose only sanitized
action counts, and bind apply to its commit, root, recovery state suffix, hash, and one-time
consumption record. Foundation, release, recovery, and read-only drift identities remain separate.

A release failure restores the prior application receipt. Database migrations remain because service
policy requires backward-compatible changes. Restoring database contents is a recovery operation with
its own approval and runbook.

The automated application graph runs the database update, JSON Keys migration and seed rotation,
Authentication migration, both backups and clean restores, private-service readiness and traffic,
dependency health, then public traffic. Authentication's candidate health endpoint proves
PostgreSQL, SMTP, and the newly active private JSON Keys gRPC path. The first launch pauses after
recovery verification while an authorized operator follows the two-phase runbook: create an inert
initializer, attach and verify its human-only tag, add the exact bootstrap configuration, then run
without overrides. The workflow records the success and the operator deletes the one-time job.
Later deployments do not repeat that gate. Cloud Scheduler continues the idempotent key-rotation job
every hour. Authentication initialization is never deployed, invoked, or retried by release or
scheduler automation.

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
