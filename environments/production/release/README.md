# Production release root

This root owns routine, manifest-driven application deployment. It selects exact container digests,
runs one-shot jobs, creates service revisions, shifts traffic, and records the release state used for
application rollback. Durable project, IAM, network, disk, snapshot, bucket-retention, and monitoring
policy stay in bootstrap or foundation state.

## State and authority

The protected release identity uses the isolated `release/` backend object. It may manage Cloud Run
services and jobs through a deployment-only custom role, manage Cloud Scheduler entries, attach five
foundation-owned non-database runtime identities, and attach only the `internal`, `release`, and
`scheduled` invocation tags. The deployment role excludes job execution, execution overrides, and
Cloud Run IAM-policy access. Foundation-owned conditional `roles/run.jobsExecutor` bindings grant
routine job execution only when the resource carries the matching permanent tag. Release cannot attach the
`initializer` tag or identity, change project IAM, VPC policy, remote-state protection, the preserved
database disk, snapshot lifecycle, backup retention, or secret payloads. Cloud Run resolves exact
numeric secret versions as the dedicated runtime identity, so release automation never reads a
credential.

Release resources keep Google-level deletion protection off because intentional cleanup must remain
possible through the repository's reviewed deletion authorization. The plan policy blocks every
managed-resource delete, replacement, and state-forget action unless the protected workflow proves
the deliberate deletion label was added by a maintainer and present when the exact PR merged. The
manual workflow rechecks that historical evidence during both plan and apply.

Routine database deployment is one tested imperative edge. The
[`deploy-database-release.sh`](../../../ops/deploy-database-release.sh) helper updates exactly seven
non-secret values on the existing foundation-owned managed instance group: commit revision, two
database image digests, two owner-password version numbers, and two backup-password version numbers.
It rejects any missing or extra field, caps the live member action at `RESTART`, and waits for the
group to become stable. An application-only release retains the preceding database revision and
skips this restart entirely.

Before a database image change or migration, the shared
[`prepare-database-change.sh`](../../../ops/prepare-database-change.sh) gate requires a ready
foundation-scheduled snapshot no older than six hours and synchronously creates both logical
backups. The empty first database release is the sole logical-backup exception because no cluster
exists yet; it still requires the snapshot. A private SHA-256 proof also requires all seven live MIG
metadata fields to match the latest immutable receipt, preventing a missing receipt or manual drift
from being treated as first launch or silently overwritten. Release can list snapshot metadata but
cannot create or delete snapshots.

For later image changes, the gate runs against the still-deployed source-image backup jobs before
the database host changes. After the new clusters pass health checks, the release root reconciles
the recovery jobs to the new image digests. The server-reported startup marker rejects the opposite
order.

The protected deployment workflow follows the fixed database → JSON Keys migration and seed rotation
→ Authentication migration → backup/clean-restore verification → private service → dependent health
check → public service order and restores the prior receipt if a health gate fails. Authentication
initialization stays outside automation because it can reset the first administrator's password and
role. On the first launch, promotion pauses after recovery verification while a named human creates
an inert job, attaches the human-only tag, verifies it, adds the exact bootstrap configuration, and
runs the job without overrides. The workflow records that exact successful execution and the human
deletes the job. Later releases and every rollback omit initialization. Backward-compatible
migrations remain applied; restoring database contents is a separate recovery operation.

Candidate reconciliation pauses every Cloud Scheduler entry before migrations or application
traffic changes. The final active reconciliation resumes them only after recovery verification,
both smoke checks, and both traffic shifts pass; compensation restores the prior active pause state.
This prevents periodic work from running against a half-migrated release without deleting and
recreating schedules.

## Current status

The root defines PostgreSQL backup, restore, freshness, and storage-monitoring jobs for JSON Keys and
Authentication. Recovery resources are created only when `database_releases` enables both databases
as one unit. When the optional atomic application contract is present, it also defines JSON Keys
migration and rotation jobs, the Authentication migration job, the private JSON Keys gRPC service,
and the public Authentication REST service. Foundation-owned tag conditions form the exact invoker
allowlists. Key rotation runs once per deployment and every hour. The one-time Authentication
initializer is deliberately absent from release state and is provisioned only by a named human
during first launch. The application contract itself requires both database release contracts. Both
components remain disabled in the production image manifest.

The protected release workflow is the root's only authenticated caller. It plans and applies only
from the reviewed `master` commit through the `production-release` GitHub environment; pull requests
and operator checkouts can validate but cannot authenticate or apply. Merging or validating this
code creates no Cloud Run revision or execution, Storage object, scheduler entry, or other cloud
resource. A maintainer must dispatch the workflow explicitly.

## Resource inventory

The provider is pinned in [`versions.tf`](./versions.tf). The links explain Google Cloud behavior a
maintainer must understand; ordinary OpenTofu syntax is not repeated.

| OpenTofu address                                     | Agora purpose and boundary                                                                                                                                                                                                                                                         | Lifecycle, recovery, and cost                                                                                                                                                                                                                                                                                                                                                                    | References                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `google_cloud_run_v2_job.postgres_backup`            | Two scale-to-zero, single-task jobs use the exact promoted database images to create custom-format logical dumps. Each job mounts one exact numeric backup-password version and writes only to an ephemeral shared volume.                                                         | Jobs retry once and time out after 30 minutes. The database image uses 1 vCPU/1 GiB; the stock uploader sidecar uses 1 vCPU/512 MiB. Both share the supported 10 GiB minimum Preview disk only while running. Jobs have no ingress.                                                                                                                                                              | [Provider job resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job), [Cloud Run jobs](https://cloud.google.com/run/docs/create-jobs), [ephemeral disk](https://cloud.google.com/run/docs/configuring/jobs/ephemeral-disk), [multi-container jobs](https://cloud.google.com/run/docs/create-jobs#multi-container), [`pg_dump`](https://www.postgresql.org/docs/18/app-pgdump.html)                         |
| `google_cloud_run_v2_job.postgres_restore`           | Two monthly jobs mount the backup bucket read-only, validate the newest committed manifest and SHA-256, then restore into a fresh local cluster with the matching database image and hardcoded service smoke checks. They receive no secret and have no production-database route. | Jobs do not retry and time out after 60 minutes. Each uses 2 vCPU/4 GiB plus the supported 10 GiB minimum Preview disk only while running. A failed restore cannot mutate production.                                                                                                                                                                                                            | [Provider job resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job), [ephemeral disk](https://cloud.google.com/run/docs/configuring/jobs/ephemeral-disk), [Cloud Storage volume mounts](https://cloud.google.com/run/docs/configuring/jobs/cloud-storage-volume-mounts), [`pg_restore`](https://www.postgresql.org/docs/18/app-pgrestore.html)                                                            |
| `google_cloud_run_v2_job.postgres_backup_monitor`    | One hourly job checks both completion manifests, the six-hour RPO, matching archive size, and all retained logical-backup bytes without reading row payloads.                                                                                                                      | It retries once, times out after five minutes, and fails above 250 GiB retained bytes. The threshold includes EU write replication and a monthly restore read while leaving headroom below the USD 20/month design gate.                                                                                                                                                                         | [Provider job resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job), [Cloud Run job monitoring](https://cloud.google.com/run/docs/monitor-jobs), [Cloud Storage pricing](https://cloud.google.com/storage/pricing)                                                                                                                                                                                        |
| Cloud Run Resource Manager tags on jobs and services | Attach one foundation-owned permanent invocation class to each protected resource. Release jobs use `release` or `scheduled`; JSON Keys uses `internal`; disposable recovery jobs/services use `recovery`. The initializer value is never present in this root.                    | Foundation-owned conditional IAM evaluates these tags. Release may attach only its three routine values and cannot rewrite Cloud Run IAM. Tags add no running component or fixed charge.                                                                                                                                                                                                         | [Cloud Run job tags](https://cloud.google.com/run/docs/configuring/jobs/tags), [Cloud Run service tags](https://cloud.google.com/run/docs/configuring/tags), [IAM tag conditions](https://cloud.google.com/iam/docs/conditions-resource-attributes#resource_tags)                                                                                                                                                                                              |
| `google_cloud_run_v2_job.application`                | Three explicit, no-ingress jobs run JSON Keys migrations and rotation plus Authentication migrations. Each job uses an exact image digest and numeric secret versions. The human-only initializer is not release-managed.                                                          | Every execution is a singleton on 1 vCPU/512 MiB. Migrations do not retry; idempotent rotation retries once. Timeouts are five or ten minutes. `ALL_TRAFFIC` plus the NAT-free VPC denies public egress, and jobs are billed only while running.                                                                                                                                                 | [Provider job resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job), [Cloud Run jobs](https://cloud.google.com/run/docs/create-jobs), [Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc), [Cloud Run secrets](https://cloud.google.com/run/docs/configuring/services/secrets)                                                                                              |
| `google_cloud_run_v2_service.json_keys`              | Runs JSON Keys on private Cloud Run ingress with its dedicated identity, h2c on port 8080, exact master-key/DSN versions, and the JSON Keys database path. All egress enters the deny-by-default VPC; there is no public internet route.                                           | The service scales from zero to three instances at concurrency 20 on 1 vCPU/512 MiB with request-based CPU. A bounded TCP startup probe checks the actual listener; the image's standard gRPC health endpoint currently alternates state for echo testing and is not a safe restart signal.                                                                                                      | [Provider service resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_service), [Cloud Run ingress](https://cloud.google.com/run/docs/securing/ingress), [end-to-end HTTP/2](https://cloud.google.com/run/docs/configuring/http2), [health checks](https://cloud.google.com/run/docs/configuring/healthchecks), [Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc)            |
| `google_cloud_run_v2_service.authentication`         | Runs the public REST edge with its dedicated identity, exact DSN/SMTP password versions, private JSON Keys host on port 443, and managed TLS SMTP on port 587. Private destinations use Direct VPC; SMTP uses Cloud Run managed public egress without NAT.                         | The service scales from zero to three instances at concurrency 20 on 1 vCPU/512 MiB. Instance-based CPU lets detached mail sends drain after a response; SMTP and shutdown are capped at five and nine seconds. `/v2/ping` startup/liveness probes test only the process. Disabling the Invoker IAM check is Google's recommended public-service configuration and avoids an `allUsers` binding. | [Provider service resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_service), [public access](https://cloud.google.com/run/docs/authenticating/public), [billing settings](https://cloud.google.com/run/docs/configuring/cpu-allocation), [health checks](https://cloud.google.com/run/docs/configuring/healthchecks), [private networking](https://cloud.google.com/run/docs/securing/private-networking) |
| `google_cloud_scheduler_job.postgres_backup`         | Starts JSON Keys at minute 15 and Authentication at minute 45 every four hours using OAuth as the exact scheduler identity.                                                                                                                                                        | One API retry handles transient dispatch failure. Scheduler acceptance is not execution success; the Cloud Run metric remains authoritative. Scheduler is usage-priced with a small free allowance.                                                                                                                                                                                              | [Provider scheduler resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_scheduler_job), [authenticated HTTP targets](https://cloud.google.com/scheduler/docs/http-target-auth)                                                                                                                                                                                                                                      |
| `google_cloud_scheduler_job.postgres_restore`        | Starts both clean restore drills on the first day of each month at 03:15 and 03:45 UTC.                                                                                                                                                                                            | Monthly scale-to-zero execution measures recoverability without a permanent staging cluster. A failed execution alerts and never reaches production PostgreSQL.                                                                                                                                                                                                                                  | [Provider scheduler resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_scheduler_job), [Cloud Scheduler overview](https://cloud.google.com/scheduler/docs/overview)                                                                                                                                                                                                                                                |
| `google_cloud_scheduler_job.postgres_backup_monitor` | Starts the recovery monitor at minute 5 every hour.                                                                                                                                                                                                                                | The hourly cadence detects a missed four-hour backup; the native absence condition alerts when this monitor has not completed for three hours.                                                                                                                                                                                                                                                   | [Provider scheduler resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_scheduler_job), [Cloud Scheduler overview](https://cloud.google.com/scheduler/docs/overview), [metric-absence alerts](https://cloud.google.com/monitoring/alerts/metric-absence)                                                                                                                                                            |
| `google_cloud_scheduler_job.json_keys_rotation`      | Starts the idempotent JSON Keys rotation job at minute 10 every hour using the exact scheduler identity. The embedded shortest rotation interval is 24 hours; hourly evaluation bounds rotation lag below one hour.                                                                | One API retry handles transient dispatch failure. The job normally exits without creating a key and scales to zero after each execution. One additional scheduler entry costs at most USD 0.10/month outside the billing account's free allowance; short executions are expected to remain within Cloud Run's free allowance.                                                                    | [Provider scheduler resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_scheduler_job), [scheduled Cloud Run jobs](https://cloud.google.com/run/docs/execute/jobs-on-schedule), [Cloud Scheduler pricing](https://cloud.google.com/scheduler/pricing)                                                                                                                                                               |

Disk-backed `emptyDir` is a Cloud Run Preview feature, so backup and restore explicitly declare the
`BETA` launch stage. Ten GiB is both Google's supported minimum and the initial per-instance quota;
this avoids a manual quota request and an extra storage or streaming component. Retries, checksums,
and monthly clean restores contain the launch risk. Revisit the workspace design if either job
approaches its duration limit or one current archive no longer fits with safe headroom.

## Application runtime contract

`application_release` is either absent or a complete six-image runtime unit. A non-null value is
rejected unless both database release contracts are also present. Every image must be the exact
regional Artifact Registry repository and immutable digest promoted from the reviewed manifest;
standalone, branch, prerelease, and undeclared future images do not enter this root.

`cloud_run_invocation_tags` contains the permanent numeric Resource Manager IDs emitted by the
foundation root. The compiler rejects names, partial maps, or non-numeric IDs. Release attaches
`release` to migrations, `scheduled` to rotation and recovery-verification jobs, and `internal` to
JSON Keys. In a disposable rebuild it attaches `recovery` only. Foundation IAM grants the narrower
`roles/run.jobsExecutor` and `roles/run.servicesInvoker` roles conditionally on those exact values,
so no release-root IAM policy is required.

The Authentication initializer remains outside this root. Foundation names its human operators and
gives them the initializer service identity, tag value, conditional invoker binding, narrow deployer
role, and registry read. The two-phase first-launch procedure creates the job without bootstrap
configuration, attaches and verifies the human-only tag, then adds exact secret versions and runs
without overrides. Release cannot attach the initializer identity or value and cannot read/change
Cloud Run IAM. Rotation seeds the database after migration during a deployment, then Cloud Scheduler
evaluates the same idempotent job hourly.

JSON Keys combines Cloud Run internal ingress with an `internal` tag condition whose sole member is
Authentication. Its h2c listener is therefore callable only by that approved internal identity, even though Cloud Run assigns the
service a `run.app` URI. `ALL_TRAFFIC` Direct VPC egress, workload tags, restricted Google API
routes, and the VPC deny fallback give it database and supported Google API access without public
internet access.

Authentication deliberately exposes its default HTTPS endpoint and disables the Cloud Run Invoker
IAM check, which is Google's recommended public-service setting. Application authentication and
authorization remain in the REST service. `PRIVATE_RANGES_ONLY` routes the private database and
Private Google Access IP ranges into the VPC while arbitrary public destinations bypass it through
Cloud Run managed egress. Private `run.app` DNS therefore keeps the JSON Keys call internal, while
TLS SMTP on port 587 needs no connector, NAT, proxy, or load balancer.

Both service blocks use receipt-owned explicit revision targets. A candidate is named immutably,
tagged, and assigned zero traffic while the prior receipt remains at 100%. JSON Keys becomes Ready
and moves first. Authentication's tagged candidate `/v2/healthcheck` then proves its PostgreSQL,
SMTP, and newly active private JSON Keys gRPC dependencies before public traffic moves. On first
launch the private service may move safely before the public edge because it has no external ingress.

## Backup and restore contract

The backup identity has `roles/storage.objectCreator` on the management backup bucket and the two
exact read-only database passwords. It cannot list, read, overwrite, or delete a recovery point. The
uploader uses the Cloud Storage JSON API with `ifGenerationMatch=0`; it uploads the dump first and
the completion manifest last.

The restore identity has `roles/storage.objectViewer` and no secret access. Its VPC tag reaches
restricted Google APIs but has no database egress rule. Restore checks the fixed 18-field manifest,
source identity, the server-reported database image startup marker and PostgreSQL major, age, size,
SHA-256, archive catalog,
single-transaction restore, the exact `plpgsql`/`uuid-ossp` extension set, declared service
tables/integrity, and validated constraints. A clean
restore cluster listens only on a local Unix socket.

Disposable recovery deliberately omits the backup writer, clean-drill/monitor, migration, rotation,
and initializer jobs. Recovery code creates no IAM on the surviving secret containers or backup
bucket. After the replacement foundation exists, a human grants its exact runtimes the documented
secret access and restore-only bucket read, then removes those bindings during cleanup.

The stock [`alpine/curl`](https://hub.docker.com/r/alpine/curl) uploader/monitor image is pinned by
complete stable SemVer and digest. The uploader command drops from the image's root default to its
built-in `nobody` account before reading the shared volume. Renovate updates only stable SemVer
releases and refreshes the digest; branch and prerelease references remain invalid. Every updated
digest must pass a high/critical image scan before merge.

## Inputs and outputs

Required inputs are:

- stable management and workload project IDs;
- the bootstrap-owned backup bucket name;
- production region, full foundation network/subnet IDs, and the database's private address;
- exact foundation-owned Authentication, JSON Keys, backup, restore, and scheduler service-account
  emails;
- the five exact foundation-owned `cloud_run_invocation_tags` permanent IDs;
- both promoted database image digests and both positive numeric backup-password versions.

`database_releases` is empty by default and must contain exactly `authentication` and `json_keys`, or
neither. Enabling one database alone fails validation. Images must match the exact production
Artifact Registry repository in the selected project and region.

Recovery-only inputs are generated by `compile-recovery.mjs` and are rejected in production state.
They bind the source project, the receipt-owned source database private address and image digests,
both exact backup attempts, and both numeric owner-password versions. The source address validates
the archive manifest only; `database_private_ip` remains the distinct empty replacement target.

`application_release` is null by default. When enabled, it requires both database releases, all six
promoted job/service digests, the five exact positive secret versions consumed by those runtimes,
SMTP host, username, and sender configuration fixed to STARTTLS submission port 587, and the first
administrator's email. Secret values remain outside OpenTofu inputs and state. Hosted-provider
account, domain, billing-cap, privacy, credential-rotation, and exit procedures live in
[Configure hosted Plunk SMTP](../../../docs/runbooks/configure-hosted-smtp.md).

Outputs contain only job, schedule, and service names plus the two Cloud Run service URIs. They
contain no secret version, credential, source manifest, bucket payload, SMTP value, or billing
value.

Read the [architecture](../../../docs/architecture.md),
[Google Cloud provider guide](../../../docs/google-cloud.md),
[cost worksheet](../../../docs/costs/production.md), and
[PostgreSQL backup and restore runbook](../../../docs/runbooks/backup-and-restore-postgresql.md)
before changing this root.
