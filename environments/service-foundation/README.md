# Single-service foundation root (inactive)

This protected root assembles one service's runtime prerequisites, Cloud Deploy control plane and
application-job access. It supports JSON Keys and Authentication; the rollout verifier currently
supports JSON Keys only. The manual foundation workflow can select this root after separately approved
configuration and activation. **Plan/apply fails before authentication unless `SERVICE_FOUNDATIONS_ENABLED=true`.**
Read-only drift and trusted PR assessment still cover initialized scopes while that writer flag is off,
using the last converged shared-foundation registration and each scope's private configuration.
The [guarded apply path](../../docs/service-operations.md#implemented-service-root-apply) binds the exact
plan inputs and holds service admission through convergence and completion publication. A held guard
also stops read-only assessment; standalone service configuration publication is refused.
Production and retained recovery evidence remain unchanged.

## Owners and state

| Owner                                                                    | Resources                                                                                                                              |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| Shared foundation and [workload project](../../modules/workload-project) | Projects, APIs, Google agents, release identity, storage namespaces, Shared VPC and host network policy.                               |
| This root                                                                | Application assets, optional private database and repository hosts/identities, and the optionally composed rollout/job-access modules. |
| [Service release](../service-release)                                    | Application job specifications, bootstrapped directly in their destination state.                                                      |
| Cloud Deploy                                                             | API specification, revisions and traffic after an approved handoff.                                                                    |

The native backend uses the published management `state_bucket` and
`foundation/services/PROJECT/default.tfstate`. Only the default workspace is accepted. The existing
`foundation/` grants supply the protected administrator and read-only plan access; routine release
and disposable recovery have separate prefixes. This is separation from routine release, not a new
administrator per service. Optional job access adds exact-guard and create-only rotation-evidence
grants for its dedicated dispatcher. Inspect inherited IAM before activation.

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
   installs exact-job authority, monitoring and JSON Keys' initially paused Scheduler → Workflows
   rotation path. The dispatcher shares service admission with protected applies. Foundation owns
   neither subsequent pause/resume decisions nor job specifications. A missing job fails its IAM
   operation; it is not recreated here.
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
Shielded VM and OS Login. Template changes are opportunistic by default; the explicit guarded bring-up
opt-in below selects proactive replacement. A crash/recreation can still interrupt this singleton database; neither preserved state
nor a warm API provides database HA. Disk and group deletion are guarded, and the disk is never an
auto-deleted attachment. Daily regional crash-consistent snapshots retain seven days; they do not replace
the management-plane logical backups or a tested restore.

The dedicated `agora-database` identity gets only its service's PostgreSQL owner and backup credentials,
application repository Reader, and log/metric writers. It has no peer, SMTP, master-key, initializer or
backup-object grant. Foundation and the project's Google APIs MIG agent may attach this exact identity.
The project owner supplies Compute Instance Admin only to protected foundation and the documented roles
to Google's Compute/MIG agents. Shared foundation supplies exact-subnet Network User to the caller and
MIG agent; the VM runtime gets no network-administration role. Verify inherited authority separately.

Both foundation paths reuse the same [host preparation adapter](../../assets/database-host).
Without `database_runtime`, this root owns **idle** group metadata: no image, credential versions or
release revision are selected. The legacy production caller keeps its existing behavior. No routine
release host mutation or automatic migration is granted here. This root must not adopt an active group
or be paired with an external metadata writer.

### Prepared database lifecycle

`database_runtime` opts the JSON Keys host into a **disabled** systemd lifecycle under protected
foundation maintenance. It requires `pgbackrest_repository.runtime` and reuses its `server_image`,
`credentials_image` and `ca_version`, so client/server compatibility has one image selector. Supply
`revision` (full reviewed commit), `password_version`, `backup_password_version` and `identity_version`
(positive numeric versions of the database owner's password, logical-backup password and client TLS
identity). No secret payload is stored in metadata. The tooling repository adds Reader only for the
database identity; TLS-secret access remains separate bootstrap custody.

Cloud-init installs the shared adapter, client configuration and `agora-database.service`, then only
reloads systemd. It replaces the metadata startup/shutdown scripts; no unit is enabled or started.
Foundation owns the selected group metadata without `ignore_changes`. Routine API releases own none
of it. Default template preparation does not update a running member or prove database readiness.

On an approved start, the existing loader delivers TLS credentials into ephemeral storage;
the shared adapter retains disk, image, password and health checks. systemd receives readiness only
after health and password activation, waits for the container's exit and bounds failure retries to
three starts per ten minutes. Docker restart is disabled for this path. Stop drains PostgreSQL before
reaping the exact consumers and removing runtime credentials. No new supervisor or boot implementation
is introduced. The client expects the reviewed PostgreSQL 18 image layout and UID/GID 999.

Only the selected repository IP on TCP 8432 is allowed out of the database bridge; host-gateway,
metadata and other initiated traffic remain blocked. Its certificate name is mapped explicitly, with
container DNS still disabled and raw-packet capability removed. The read-only client credential mount
contains no cloud token. WAL archiving defaults off; the prepared jobs below share this network.
Daily logical backups remain unchanged.

`database_runtime.bring_up` defaults to false. With separately approved
`NATIVE_BACKUP_MAINTENANCE_ENABLED` and `NATIVE_BACKUP_BRINGUP_ENABLED` workflow gates, it enrolls
disruptive foundation applies in [guarded bring-up](../../docs/service-operations.md#native-online-backups).
The provider owns proactive stateful RECREATE updates with one unavailable member and zero surge;
the disk and IP stay preserved. This singleton maintenance needs a downtime window.
The repository's desired state becomes RUNNING. Custody uses the sensitive `native_bringup` output
privately, reboots the quiesced repository through blocking stop/start, checks the loaded configuration,
and starts repository then database through systemd. Successful native repository access and database
health are required before releasing admission. Timers stay off, and COS boot still only registers units.
No-op/monitor-only applies never restart hosts. An interrupted bring-up needs explicit reconciliation;
neither another apply nor a healthy current host can substitute for missing completion evidence.

Before activation, separately review operation admission, exact image/credential evidence, empty-disk
versus existing-data handling, network/IAM denials, TLS delivery failure, startup interruption, crash
restart and Docker/host shutdown on COS. Neither these mocked tests nor the earlier offline TLS proof
substitutes for that rehearsal. A database image change is maintenance, not an API rollout; do not
automatically replay migrations or downgrade an existing data directory.

The published document includes the version-1 `database` output without granting state access. A stable
MIG and private IP are only provisioning evidence. Before activation, verify the disabled unit (or the
legacy boot-bound `idle` status), allowed/denied host
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

### Prepared native backup jobs

The database lifecycle also installs five disabled `agora-backup-<operation>.service` units from one
template: `stanza-create`, `check`, `full`, `diff` and `verify`. Three disabled timers prepare a weekly full
(Sunday 02:00 UTC), differential (Monday–Saturday 02:00 UTC), and hourly archive check (:30 UTC),
with up to five minutes of jitter. Nothing starts or enables them on boot. Missed runs do not catch
up automatically; no timer creates the stanza or runs expiry. These are initial review settings,
not a measured RPO or permission to activate scheduling.
After separate activation approval, foundation can set `database_runtime.wal_archiving = true` to
enable PostgreSQL's native `pgbackrest --stanza=json-keys archive-push %p` command. This requires a
database maintenance restart, not an API release. The default explicitly clears archiving on existing
data too; do not toggle an active WAL chain without reviewing its recovery consequences.

Each job runs a foreground container on the existing database VM with the same reviewed image.
It reads database files and the local socket through read-only mounts, shares pgBackRest's lock
directory and uses the database's restricted network namespace and host-name mapping. The worker has
no host control socket or cloud token. Its SQL connection has the database owner's authority; the
read-only data mount is not a separate database trust boundary.

systemd requires the database to be active without starting it. Jobs have a one-hour limit, bounded
stop cleanup and no automatic retries. Database stop propagates to workers without replaying them on
restart; database failure cleanup also reaps their exact container names before removing credentials.
pgBackRest owns conflicting-operation locks, WAL checks and completion metadata. Automatic expiry is
disabled in the shared configuration and each job. Failed jobs require inspection before explicit retry;
the next calendar event is an independent scheduled attempt, not an automatic command retry.

Routine online backups/checks and continuous WAL archiving use native pgBackRest coordination rather
than acquiring the service-wide deployment guard. Disruptive maintenance and recovery retain protected
[service admission](../../docs/service-operations.md#native-online-backups). Stop all three timers and
drain workers before maintenance; a database stop also stops them without restarting them afterward.
Stopping timers does **not** stop PostgreSQL's continuous archiver. Work requiring exclusive repository
access must quiesce that writer too. An API release must not control this lifecycle.

Each worker keeps one exited container with at most two 2 MiB Docker log files until its next run.
COS's existing collector reads these logs; no second agent, cloud dispatcher or database-host grant is
added. Database cleanup stops workers but preserves their logs. Startup failures/timeouts also have
systemd journal evidence. Logs can still be lost on host loss or collection outage; the independent
missing-success conditions cover that uncertainty, not proof of recovery.

Five disabled Cloud Monitoring policies use the existing operations channel: native command/unit
errors, Sunday's full-backup deadline (04:00 UTC), any backup (24 hours 45 minutes), archive check
(three hours), disk pressure (85%) or missing disk telemetry (one hour). PromQL explicitly covers
zero/never-seen samples; a standard absence condition would require prior history. The full check
evaluates Sunday 04:00–23:59 UTC against the preceding 24 hours; it is not continuous full-chain age
monitoring, and Monday's automatic closure does not prove a repair. Log-based alert lookbacks plus
retest windows must stay within [Google's 25-hour limit](https://docs.cloud.google.com/monitoring/alerts/using-promql).
The policies bind the current numeric VM ID;
protected host replacement must reconcile them. Native success is not dependency integrity or SQL
restore evidence. See [alert response](../../docs/runbooks/respond-to-alerts.md#native-backup-pilot).

Before activation, rehearse shared-socket access, native lock contention, stop/timeout and database/
Docker failure on COS. Verify maintenance admission, default COS log fields, startup-failure/timeout
events, first/zero/missing successes, stopped-host detection, alert delivery, data-disk metric coverage,
backup age, WAL growth, repository outage and isolated SQL restore. Archive failures retain WAL and
can fill the database disk; no WAL-discard limit
is configured. This preparation adds no VM or cloud grant, but future backup I/O and stored WAL cost
money. No resources are applied here; log-based metrics, stored logs and future backup traffic are not
a zero-cost guarantee. Scheduling activation, expiry and retirement of existing protection remain
separately reviewed work.

### Native integrity check

`agora-backup-verify.service` is operator-invoked after separate activation approval; it has no timer.
It uses the shared worker's one-hour, 0.5-CPU and 512-MiB limits and native TLS connection to read the
repository. Verification adds no cloud permissions or repository writes. Reads and transfer still
cost money; measure a complete scan before choosing a schedule or increasing its limits.

Inspect the retained `agora-backup-verify` Docker logs and systemd journal. pgBackRest 2.59.1 can exit
zero while reporting `status: error`; systemd completion alone is insufficient. The disabled failure
alert also matches that worker's error and empty-repository reports. Its verbose report must cover the
expected backup sets and WAL; an empty, partial, interrupted or missing report is not verification.
Export evidence before another invocation replaces the worker's logs. No verification result feeds
the backup-success metric or authorizes repair, expiry or restore.

The [offline proof](../../proofs/pgbackrest#native-repository-transport) exercises healthy, empty,
missing and corrupt data through native TLS. GCS behavior, COS log delivery and notifications still
need live evidence. Native integrity checks complement isolated SQL restore drills.

## Optional stopped repository host

`pgbackrest_repository = null` creates nothing. For JSON Keys with a declared `database`, an explicit
`pgbackrest_repository = {}` prepares one private COS VM and its `agora-backup-repository` identity.
It uses the database's reviewed zone, subnet and COS image, an **e2-micro** candidate and one 20 GiB
**pd-standard** boot disk. The only capacity override is `machine_type = "e2-small"`; select it only
after measurement. Neither profile is a proven backup-throughput or monthly-cost guarantee.

By default the native instance resource converges to `TERMINATED`. Creation can briefly boot the VM before the
provider stops it; the boot disk remains billable while stopped. The host has no database disk,
public IP, guest-attribute readiness or running repository daemon. Deletion is guarded.
An image replacement needs an explicit maintenance review; the root grants no automatic rollout or
application-release control over this host. Existing database metadata and coordinates are unchanged.

Only protected foundation receives attachment permission on the repository identity. With runtime
absent, this root gives it no secret, registry or project-level role. The separate [bootstrap custody option](../../bootstrap/README.md#disabled-json-keys-native-backup-custody)
grants its native bucket access after the identity exists. Bootstrap retains ownership of that bucket,
its writer/recovery roles and disabled recovery identity. The standalone `pgbackrest_repository` output
describes host coordinates; it is not readiness evidence, published in application coordinates or consumed by release.
The existing protected input materializer and private configuration publisher preserve the opt-in.

Activation needs a reviewed native TLS runtime/certificate lifecycle, host filesystem and egress
limits, image delivery, monitoring and restore proof. Shared foundation remains the network-policy
owner; it must authorize only the selected database-to-repository channel and required private Google
APIs. Inspect inherited IAM and project metadata before provisioning. No new firewall, public address,
NAT, secret grant or telemetry grant is supplied by this preparation.

### Prepared native runtime

The optional `pgbackrest_repository.runtime` object installs public configuration through COS
cloud-init and adds Reader on this project's two image repositories. It requires these generated
deployment inputs; maintained image dependencies still use SemVer:

| Field               | Required value                                                                                                   |
| ------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `server_image`      | Approved promoted digest at `REGION-docker.pkg.dev/PROJECT/agora-production/service-json-keys/database@sha256:…` |
| `credentials_image` | Approved promoted digest at `REGION-docker.pkg.dev/PROJECT/agora-tooling/host-credentials@sha256:…`              |
| `ca_version`        | Positive numeric version of the public CA secret                                                                 |
| `identity_version`  | Positive numeric version of the repository PEM identity secret                                                   |

The management project number and native bucket come from `state_bucket`. The server certificate
must cover `agora-pgbackrest-json-keys.ZONE.c.PROJECT.internal`; the authorized database client CN is
`agora-database.PROJECT`. Reconcile these names with the separately approved issuer and zonal DNS
before activation. Input syntax checks do not prove provenance, effective grants or certificate custody.

Boot only writes the configuration and registers `agora-backup-repository.service`; it neither pulls
images nor reads secrets nor starts/enables the service. This also covers the brief creation boot.
COS recreates `/etc` each boot. There is no `[Install]` target or automatic service restart.

One systemd service owns the future runtime. Its pre-start commands pull the exact artifacts through
COS's metadata-backed registry helper, create a private ephemeral parent and run the existing
[credential loader](../../cmd/host-credentials/README.md). The server starts only after successful
delivery. Both containers run as UID/GID 999 with bounded resources, a read-only root and no host
control socket. Only the delivered directory is mounted read-only into the server. Stop/failure
cleanup reaps the two service-owned container names before systemd removes its runtime directory.
No custom supervisor or credential proxy is involved.

The database client and repository process share the service's **backup-writer trust boundary**,
including server-readable files and writer authority. TLS authenticates the client; it does not
hide the server's identity from it. Independent recovery authority remains outside that boundary.
The dedicated host has no database password or application secrets. PostgreSQL's direct metadata
denial is unchanged. Effective peer, policy and recovery denials still require live verification.

Do not start this unit until publication/promotion, credential issuance and expiry/revocation,
effective IAM/egress, operation admission, monitoring and a scoped COS lifecycle proof are approved.
That proof must include failed credential delivery, interrupted startup, server stop and restart,
and Docker/host failure. Unit-active is not backup readiness. Metadata updates do not reload a running
service; changing versions requires a separately admitted stopped-consumer lifecycle. Existing
backup writers and daily snapshots remain unchanged.

References: [COS cloud-init](https://docs.cloud.google.com/container-optimized-os/docs/how-to/create-configure-instance),
[systemd service cleanup](https://github.com/systemd/systemd/blob/v257/man/systemd.service.xml),
[runtime directory lifetime](https://github.com/systemd/systemd/blob/v257/man/systemd.exec.xml).

The design ceiling is EUR 10–15 additional per service per month, with minimum tested capacity as the
target. Confirm local-currency compute/disk rates and budget storage generations, requests, networking,
logs and temporary overlap before live approval. Compare the whole replacement against costs actually
retired. Existing logical backups and daily snapshots remain active until their respective reviewed
cutovers; retained logical recovery points keep their readers and images through expiration.

Google documents the [native instance lifecycle](https://github.com/hashicorp/terraform-provider-google/blob/v8.2.0/website/docs/r/compute_instance.html.markdown)
and [single attached service-account boundary](https://docs.cloud.google.com/compute/docs/access/service-accounts).
This preparation proves resource intent only; effective isolation and recovery require the separate
activation evidence in [the backup runbook](../../docs/runbooks/backup-and-restore-postgresql.md#native-backup-preparation).

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
