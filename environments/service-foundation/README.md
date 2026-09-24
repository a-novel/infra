# Single-service foundation root (inactive)

This protected root assembles one service's runtime prerequisites, Cloud Deploy control plane and
application-job access. It supports JSON Keys and Authentication; the rollout verifier currently
supports JSON Keys only. The manual foundation workflow can select this root after separately approved
configuration and activation. **Plan/apply fails before authentication unless `SERVICE_FOUNDATIONS_ENABLED=true`.**
Read-only drift and trusted PR assessment still cover initialized scopes while that writer flag is off,
using the last converged shared-foundation registration and each scope's private configuration.
Production and retained recovery evidence remain unchanged.

## Owners and state

| Owner                                                                    | Resources                                                                                                                    |
| ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| Shared foundation and [workload project](../../modules/workload-project) | Projects, APIs, Google agents, release identity, storage namespaces, Shared VPC and host network policy.                     |
| This root                                                                | Application assets, optional private database host/storage/identity, and the optionally composed rollout/job-access modules. |
| [Service release](../service-release)                                    | Application job specifications, bootstrapped directly in their destination state.                                            |
| Cloud Deploy                                                             | API specification, revisions and traffic after an approved handoff.                                                          |

The native backend uses the published management `state_bucket` and
`foundation/services/PROJECT/default.tfstate`. Only the default workspace is accepted. The existing
`foundation/` grants supply the protected administrator and read-only plan access; routine release
and disposable recovery have separate prefixes. This is separation from routine release, not a new
administrator per service. No storage grant is added here. Inspect inherited IAM before activation.

Authorize project, region and bucket against the published foundation coordinates **before init**.
The bucket-name validation establishes syntax only. Use a fresh working directory and disallow backend
overrides. Keep private state backup, exact saved-plan custody and deletion authorization. Native
[GCS locking](https://opentofu.org/docs/language/settings/backends/gcs/) covers this root only;
foundation changes, service releases, migrations and scheduled mutations still require coordinated exclusion.

## Runtime prerequisites

`main.tf` owns the application identity, two runtime-secret grants, repositories and operations email
channel directly. It reads no secret payload. Authentication receives its PostgreSQL and SMTP secret
containers; JSON Keys receives its PostgreSQL credential and master key. Neither receives peer,
backup or initializer credentials. Numeric enabled-version selection remains release policy.

Protected foundation receives [Secret Manager Viewer](https://docs.cloud.google.com/secret-manager/docs/access-control)
on the selected jobs' secrets: PostgreSQL and the master key for JSON Keys, PostgreSQL alone for
Authentication. This permits metadata and version listings without payload access or version mutation.
These additive grants leave the shared container-administration role unchanged. Foundation remains a
shared, trusted administrator; verify inherited permissions separately before activation.

`agora-production` holds application images and grants the project-local release identity Writer.
`agora-tooling` keeps verifier publication separate. Both repositories have immutable tags, deletion
guards and no age-based cleanup; recovery can read retained images. A separately approved publisher
must promote and verify the tooling digest. No verifier writer is granted here.

The version-1 `runtime` output supplies the published document and the child modules' identity and
operations channel; callers cannot override those with a peer's coordinates. Its output waits for
runtime-secret, bootstrap metadata and application-publisher grants.
Channel creation still needs a delivery test. Protected foundation receives identity attachment on
the exact application account for approved job bootstrap.

## Published coordinates

`coordinates.tf` publishes one JSON document in the management state bucket at
`foundation/coordinates/PROJECT/SHA256.json`. Its version-1 envelope contains only the existing
`runtime`, optional `database` and optional `rollout` outputs. It excludes private inputs, secret
versions/payloads and peer state. Database coordinates describe an **idle** host; rollout coordinates
identify a **suspended** pipeline. These are configuration snapshots, not readiness evidence.

The selected project's release account gets Object Viewer on that exact managed folder. It gains no
foundation-state access or write permission. The foundation administrator and plan reader retain their
existing parent grants. Check inherited IAM before activation; managed-folder grants are additive.

The `coordinates` output is the reference: schema version, bucket, object name, native generation and
SHA-256 of the serialized bytes. A consumer must receive this reference through reviewed protected
configuration after the whole apply, convergence and private-configuration publication succeed. It
must verify the approved scope, generation and checksum. Never discover a version by listing objects
or treating the newest generation as approved; an object can survive a later apply failure. No routine
release caller or automatic approval is enabled by this root.

The native provider replaces the managed object when its content-derived name changes and uses
`ABANDON` to retain the previous document. The managed-folder deletion guard remains in force. Keep
every referenced document through its consumers' and recovery evidence's lifetime. Foundation can
still overwrite objects; content addressing requires consumer checksum verification. Returning to
older content can create a new generation at its old name, so preserve the approved native generation
and inspect bucket version-retention rules. A failed or interrupted publication requires a new reviewed
plan and state reconciliation; it does not authorize retrying a deployment or migration.

This uses OpenTofu's [explicit publication pattern](https://opentofu.org/docs/language/state/remote-state-data/)
and the pinned provider's [object lifecycle](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/storage_bucket_object.html.markdown).
Project/federation and host-network coordinates remain separately protected inputs. No state reader,
custom publisher or mutable latest pointer is introduced.

## Bootstrap sequence

The optional inputs describe which prerequisites already exist. They do not attest successful
bootstrap, execute a job or activate the pilot. Keep each enabled configuration in the protected
inputs; dropping it is resource removal, subject to its lifecycle guards and deletion review.

1. Establish the service project, agents, host network grants and approved foundation executor.
   Apply this root with `database = null`, `rollout = null` and `manage_job_access = false` to create runtime prerequisites.
2. After reviewed verifier promotion, supply `rollout` with `verification_image`, `network` and
   `subnetwork`. The root derives the fixed JSON Keys API name, service-local artifact bucket and
   management receipt bucket. The image must belong to this project's separate tooling repository.
   The [rollout module](../../modules/cloud-run-rollout) remains hard-suspended, with target approval
   required. Authentication rejects this opt-in until its own verifier is implemented.
3. After the selected database and approved images exist, protected bootstrap creates application jobs
   in [service-release state](../service-release#bootstrap-before-routine-release). Reconcile exact
   job UIDs and state before setting `manage_job_access = true`. The [job-access module](../../modules/service-job-access)
   installs exact-job authority, monitoring and JSON Keys' hard-paused rotation schedule. It owns no
   job specification. A missing job fails its IAM operation; it is not recreated here.
4. Verify allowed/denied IAM and network paths, remove temporary bootstrap authority and prove
   zero-change convergence before connecting routine release. Neither switch unsuspends Cloud Deploy
   nor resumes rotation. Their separate activation and interruption drills remain required.

Steps 2 and 3 consume different prerequisites and can be reviewed independently. OpenTofu composes
the dependency graph; there is no setup script, `-target` bootstrap or automatic existence discovery.
The [workload project](../../modules/workload-project#protected-provisioning-authority) declares the
protected executor's project permissions and the plan reader's policy access. This root derives the
executor as `infra-foundation@MANAGEMENT_PROJECT.iam.gserviceaccount.com`; child modules grant attachment
on their exact identities before creating targets, probes or schedules. Check that this is the same
executor used by shared foundation. Management secret-IAM maintenance, state/receipt bucket access
and host-network grants remain separate bootstrap prerequisites.

An existing pilot owner requires a private state backup and explicit removal/import map before this
root adopts its resources. Import cannot move a legacy workload into another project. Keep the old
writer until its separate workload cutover is verified. Database activation/backups, approved coordinate
references for consumers, same-service exclusion, receipt completion and live failure drills remain
unfinished activation work. The active coordinator is retained until its replacement is proven.

## Optional idle database host

`database.tf`, `database-access.tf` and `database-snapshots.tf` directly own one private host in the
selected project; there is no fleet map or wrapper module. An explicit `database` object supplies the
approved zone, canonical subnet ID and pinned COS image. Defaults retain the reviewed small profile:
e2-medium (4 GiB host RAM), 50 GiB **pd-balanced SSD**, 0.75 container vCPU, 1,536 MiB container memory
and 50 PostgreSQL connections. Validation reserves at least 1 GiB/0.5 vCPU for COS. Larger reviewed e2
profiles are available without changing the service's storage owner. Backend/project/subnet authorization
and available regional quota still require protected preflight; syntax checks do not provide either.

The zonal stateful MIG has exactly one member, a preserved data disk and internal IP, no external IP,
Shielded VM and OS Login. Template changes are opportunistic: applying foundation does not roll the
running member. A crash/recreation can still interrupt this singleton database; neither preserved state
nor a warm API provides database HA. Disk and group deletion are guarded, and the disk is never an
auto-deleted attachment. Daily regional crash-consistent snapshots retain seven days; they do not replace
the management-plane logical backups or a tested restore.

The dedicated `agora-database` identity gets only its service's PostgreSQL owner and backup credentials,
application repository Reader, and log/metric writers. It has no peer, SMTP, master-key, initializer or
backup-object grant. Foundation and the project's Google APIs MIG agent may attach this exact identity.
The project owner supplies Compute Instance Admin only to protected foundation and the documented roles
to Google's Compute/MIG agents. Shared foundation supplies exact-subnet Network User to the caller and
MIG agent; the VM runtime gets no network-administration role. Verify inherited authority separately.

Both foundation paths use the same [host assets](../../assets/database-host), relocated without changing
their bytes. The current production templates, resource addresses and backup/receipt formats are unchanged.
Unlike the legacy coordinator, this root owns its **idle** group metadata without `ignore_changes`: no
image, credential versions or release revision are selected. It must not adopt an active group or be
paired with an external metadata writer. Future activation must explicitly replace this idle-only
contract with one reviewed owner and safe maintenance/reconciliation behavior, not bypass it with drift.
No routine release host mutation or automatic migration is granted here.

The published document includes the version-1 `database` output without granting state access. A stable
MIG and private IP are only provisioning evidence. Before activation, verify the boot-bound `idle` status, allowed/denied host
and container network paths, exact secret/image access, image provenance, application health and backup/
restore evidence. The current host firewall still addresses the legacy database IPs; approving the new
IP rules and proving peer denial belongs to the separate network/cutover change. Do not route an API to
this idle host. Operator IAP/OS Login access, backup jobs, resource monitoring and interrupted database
maintenance remain activation work. The [protected planning path](../../docs/runbooks/provision-service-projects.md#protected-service-foundation-plans)
requires separate live authorization.

The maintained [Google VM module v15.3.0](https://github.com/terraform-google-modules/terraform-google-vm/blob/v15.3.0/modules/instance_template/versions.tf)
requires providers below v8, incompatible with this repository's v8.2.0 pin. Native resources retain
[stateful MIG](https://docs.cloud.google.com/compute/docs/instance-groups/how-stateful-migs-work) behavior
without weakening upstream constraints or adding a controller. Runtime/backup replacement remains #190.

## Cloud-blind validation

The existing validation job checks both inactive service roots with pinned providers and disabled
backends. Plan-only tests mock every provider, preserve the modules' security cases and exercise their
composition with each service. These tests contact no cloud API and do not prove effective cloud
permissions, publication delivery or live health.

```sh
tofu -chdir=environments/service-foundation init -backend=false -input=false -lockfile=readonly
tofu -chdir=environments/service-foundation validate
tofu -chdir=environments/service-foundation test
```

The root uses native [flat module composition](https://opentofu.org/docs/language/modules/develop/composition/).
Storage authority follows [managed-folder inheritance](https://docs.cloud.google.com/storage/docs/managed-folders).
The [onboarding boundary](../../docs/runbooks/provision-service-projects.md) remains the live-operation gate.
