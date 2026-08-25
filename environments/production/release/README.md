# Production release root

This root owns routine, manifest-driven application deployment. It selects exact container digests,
runs one-shot jobs, creates service revisions, shifts traffic, and records the release state used for
application rollback. Durable project, IAM, network, disk, snapshot, bucket-retention, and monitoring
policy stay in bootstrap or foundation state.

## State and authority

The protected release identity uses the isolated `release/` backend object. It may manage Cloud Run
services and jobs, Cloud Scheduler entries, attach the five foundation-owned non-database runtime
identities, and set IAM policies on release-owned services and jobs through separate custom roles
containing only the matching `getIamPolicy` and `setIamPolicy` permissions. It cannot change project
IAM, VPC policy, remote-state protection, the preserved database disk, snapshot lifecycle, backup
retention, or secret payloads. Cloud Run resolves exact numeric secret versions as the dedicated
runtime identity, so release automation never reads a credential.

Release resources keep Google-level deletion protection off because intentional cleanup must remain
possible through the repository's reviewed deletion authorization. The plan policy blocks every
managed-resource delete, replacement, and state-forget action unless the protected workflow proves
the deliberate deletion label. This root has no workflow caller yet, so that exception is not
currently executable.

Routine database deployment is one tested imperative edge. The
[`deploy-database-release.sh`](../../../ops/deploy-database-release.sh) helper updates exactly seven
non-secret values on the existing foundation-owned managed instance group: commit revision, two
database image digests, two owner-password version numbers, and two backup-password version numbers.
It rejects any missing or extra field and caps the live member action at `RESTART`.

Before a database image change or migration, the shared
[`prepare-database-change.sh`](../../../ops/prepare-database-change.sh) gate requires a ready
foundation-scheduled snapshot no older than six hours and synchronously creates both logical
backups. The empty first database release is the sole logical-backup exception because no cluster
exists yet; it still requires the snapshot. Release can list snapshot metadata but cannot create or
delete snapshots.

For later image changes, the gate runs against the still-deployed source-image backup jobs before
the database host changes. After the new clusters pass health checks, the release root reconciles
the recovery jobs to the new image digests. The server-reported startup marker rejects the opposite
order.

The protected deployment workflow must follow the fixed database → jobs → private service → public
service order and restore the prior receipt if a health gate fails. Backward-compatible migrations
remain applied; restoring database contents is a separate recovery operation. Until that workflow
can create zero-traffic candidate revisions, smoke-test them, and shift traffic, the optional
application release input must remain unset.

## Current status

The root defines PostgreSQL backup, restore, freshness, and storage-monitoring jobs for JSON Keys and
Authentication. Recovery resources are created only when `database_releases` enables both databases
as one unit. When the optional atomic application contract is present, it also defines JSON Keys
migration and rotation jobs, Authentication migration and initialization jobs, the private JSON Keys
gRPC service, its exact invoker allowlist, and the public Authentication REST service. The
application contract itself requires both database release contracts. Both components remain
disabled in the production image manifest.

No protected release workflow exists yet, so the root has no authenticated caller and cannot be
applied from GitHub or an operator checkout. Merging or validating this code creates no Cloud Run
revision or execution, Storage object, scheduler entry, or other cloud resource.

## Resource inventory

The provider is pinned in [`versions.tf`](./versions.tf). The links explain Google Cloud behavior a
maintainer must understand; ordinary OpenTofu syntax is not repeated.

| OpenTofu address                                           | Agora purpose and boundary                                                                                                                                                                                                                                                         | Lifecycle, recovery, and cost                                                                                                                                                                                                                                                                                                                                                                    | References                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `google_cloud_run_v2_job.postgres_backup`                  | Two scale-to-zero, single-task jobs use the exact promoted database images to create custom-format logical dumps. Each job mounts one exact numeric backup-password version and writes only to an ephemeral shared volume.                                                         | Jobs retry once and time out after 30 minutes. The database image uses 1 vCPU/1 GiB; the stock uploader sidecar uses 1 vCPU/512 MiB. Both share the supported 10 GiB minimum Preview disk only while running. Jobs have no ingress.                                                                                                                                                              | [Provider job resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job), [Cloud Run jobs](https://cloud.google.com/run/docs/create-jobs), [ephemeral disk](https://cloud.google.com/run/docs/configuring/jobs/ephemeral-disk), [multi-container jobs](https://cloud.google.com/run/docs/create-jobs#multi-container), [`pg_dump`](https://www.postgresql.org/docs/18/app-pgdump.html)                         |
| `google_cloud_run_v2_job.postgres_restore`                 | Two monthly jobs mount the backup bucket read-only, validate the newest committed manifest and SHA-256, then restore into a fresh local cluster with the matching database image and hardcoded service smoke checks. They receive no secret and have no production-database route. | Jobs do not retry and time out after 60 minutes. Each uses 2 vCPU/4 GiB plus the supported 10 GiB minimum Preview disk only while running. A failed restore cannot mutate production.                                                                                                                                                                                                            | [Provider job resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job), [ephemeral disk](https://cloud.google.com/run/docs/configuring/jobs/ephemeral-disk), [Cloud Storage volume mounts](https://cloud.google.com/run/docs/configuring/jobs/cloud-storage-volume-mounts), [`pg_restore`](https://www.postgresql.org/docs/18/app-pgrestore.html)                                                            |
| `google_cloud_run_v2_job.postgres_backup_monitor`          | One hourly job checks both completion manifests, the six-hour RPO, matching archive size, and all retained logical-backup bytes without reading row payloads.                                                                                                                      | It retries once, times out after five minutes, and fails above 250 GiB retained bytes. The threshold includes EU write replication and a monthly restore read while leaving headroom below the USD 20/month design gate.                                                                                                                                                                         | [Provider job resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job), [Cloud Run job monitoring](https://cloud.google.com/run/docs/monitor-jobs), [Cloud Storage pricing](https://cloud.google.com/storage/pricing)                                                                                                                                                                                        |
| `google_cloud_run_v2_job_iam_member.*_scheduler`           | Grants the foundation-owned scheduler identity `roles/run.invoker` on only these five release jobs.                                                                                                                                                                                | Additive bindings expose no public or user invoker. Release uses a two-permission custom foundation role to set job IAM without Cloud Run Admin. IAM has no fixed charge.                                                                                                                                                                                                                        | [Provider job IAM resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job_iam), [Cloud Run IAM roles](https://cloud.google.com/run/docs/reference/iam/roles)                                                                                                                                                                                                                                                 |
| `google_cloud_run_v2_job.application`                      | Four explicit, no-ingress jobs run JSON Keys migrations and key rotation followed by Authentication migrations and first-admin initialization. Each job uses its service's identity, exact image digest, exact numeric secret versions, and database-specific Direct VPC tag.      | Every execution is a singleton on 1 vCPU/512 MiB. Migrations do not retry; idempotent rotation and initialization retry once. Timeouts are five or ten minutes. `ALL_TRAFFIC` plus the NAT-free VPC denies public egress, and jobs are billed only while running.                                                                                                                                | [Provider job resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job), [Cloud Run jobs](https://cloud.google.com/run/docs/create-jobs), [Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc), [Cloud Run secrets](https://cloud.google.com/run/docs/configuring/services/secrets)                                                                                              |
| `google_cloud_run_v2_service.json_keys`                    | Runs JSON Keys on private Cloud Run ingress with its dedicated identity, h2c on port 8080, exact master-key/DSN versions, and the JSON Keys database path. All egress enters the deny-by-default VPC; there is no public internet route.                                           | The service scales from zero to three instances at concurrency 20 on 1 vCPU/512 MiB with request-based CPU. A bounded TCP startup probe checks the actual listener; the image's standard gRPC health endpoint currently alternates state for echo testing and is not a safe restart signal.                                                                                                      | [Provider service resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_service), [Cloud Run ingress](https://cloud.google.com/run/docs/securing/ingress), [end-to-end HTTP/2](https://cloud.google.com/run/docs/configuring/http2), [health checks](https://cloud.google.com/run/docs/configuring/healthchecks), [Direct VPC egress](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc)            |
| `google_cloud_run_v2_service_iam_member.json_keys_invoker` | Grants `roles/run.invoker` on JSON Keys only to Authentication and the protected release/recovery identities used for rollout and recovery checks.                                                                                                                                 | Three additive bindings contain no public or general authenticated principal. Internal ingress and signed identity are independent requirements. IAM has no fixed charge.                                                                                                                                                                                                                        | [Provider service IAM resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_service_iam), [service-to-service authentication](https://cloud.google.com/run/docs/authenticating/service-to-service), [Cloud Run IAM roles](https://cloud.google.com/run/docs/reference/iam/roles)                                                                                                                               |
| `google_cloud_run_v2_service.authentication`               | Runs the public REST edge with its dedicated identity, exact DSN/SMTP password versions, private JSON Keys host on port 443, and managed TLS SMTP on port 587. Private destinations use Direct VPC; SMTP uses Cloud Run managed public egress without NAT.                         | The service scales from zero to three instances at concurrency 20 on 1 vCPU/512 MiB. Instance-based CPU lets detached mail sends drain after a response; SMTP and shutdown are capped at five and nine seconds. `/v2/ping` startup/liveness probes test only the process. Disabling the Invoker IAM check is Google's recommended public-service configuration and avoids an `allUsers` binding. | [Provider service resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_service), [public access](https://cloud.google.com/run/docs/authenticating/public), [billing settings](https://cloud.google.com/run/docs/configuring/cpu-allocation), [health checks](https://cloud.google.com/run/docs/configuring/healthchecks), [private networking](https://cloud.google.com/run/docs/securing/private-networking) |
| `google_cloud_scheduler_job.postgres_backup`               | Starts JSON Keys at minute 15 and Authentication at minute 45 every four hours using OAuth as the exact scheduler identity.                                                                                                                                                        | One API retry handles transient dispatch failure. Scheduler acceptance is not execution success; the Cloud Run metric remains authoritative. Scheduler is usage-priced with a small free allowance.                                                                                                                                                                                              | [Provider scheduler resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_scheduler_job), [authenticated HTTP targets](https://cloud.google.com/scheduler/docs/http-target-auth)                                                                                                                                                                                                                                      |
| `google_cloud_scheduler_job.postgres_restore`              | Starts both clean restore drills on the first day of each month at 03:15 and 03:45 UTC.                                                                                                                                                                                            | Monthly scale-to-zero execution measures recoverability without a permanent staging cluster. A failed execution alerts and never reaches production PostgreSQL.                                                                                                                                                                                                                                  | [Provider scheduler resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_scheduler_job), [Cloud Scheduler overview](https://cloud.google.com/scheduler/docs/overview)                                                                                                                                                                                                                                                |
| `google_cloud_scheduler_job.postgres_backup_monitor`       | Starts the recovery monitor at minute 5 every hour.                                                                                                                                                                                                                                | The hourly cadence detects a missed four-hour backup; the native absence condition alerts when this monitor has not completed for three hours.                                                                                                                                                                                                                                                   | [Provider scheduler resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_scheduler_job), [Cloud Scheduler overview](https://cloud.google.com/scheduler/docs/overview), [metric-absence alerts](https://cloud.google.com/monitoring/alerts/metric-absence)                                                                                                                                                            |

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

JSON Keys combines Cloud Run internal ingress with an exact IAM invoker allowlist. Its h2c listener
is therefore callable only by approved internal identities, even though Cloud Run assigns the
service a `run.app` URI. `ALL_TRAFFIC` Direct VPC egress, workload tags, restricted Google API
routes, and the VPC deny fallback give it database and supported Google API access without public
internet access.

Authentication deliberately exposes its default HTTPS endpoint and disables the Cloud Run Invoker
IAM check, which is Google's recommended public-service setting. Application authentication and
authorization remain in the REST service. `PRIVATE_RANGES_ONLY` routes the private database and
Private Google Access IP ranges into the VPC while arbitrary public destinations bypass it through
Cloud Run managed egress. Private `run.app` DNS therefore keeps the JSON Keys call internal, while
TLS SMTP on port 587 needs no connector, NAT, proxy, or load balancer.

Both service blocks currently express the API's bootstrap default of 100% traffic to the latest
ready revision. The application input must stay unset until protected deployment replaces this with
receipt-owned explicit revision targets: the candidate receives zero traffic, passes smoke checks,
then JSON Keys shifts before Authentication. This repository has no unsafe interim caller.

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
- both promoted database image digests and both positive numeric backup-password versions.

`database_releases` is empty by default and must contain exactly `authentication` and `json_keys`, or
neither. Enabling one database alone fails validation. Images must match the exact production
Artifact Registry repository in the selected project and region.

`application_release` is null by default. When enabled, it requires both database releases, all six
promoted job/service digests, the five exact positive secret versions consumed by those runtimes,
SMTP host/sender configuration fixed to TLS submission port 587, and the first administrator's
email. Secret values remain outside OpenTofu inputs and state.

Outputs contain only job, schedule, and service names plus the two Cloud Run service URIs. They
contain no secret version, credential, source manifest, bucket payload, SMTP value, or billing
value.

Read the [architecture](../../../docs/architecture.md),
[Google Cloud provider guide](../../../docs/google-cloud.md),
[cost worksheet](../../../docs/costs/production.md), and
[PostgreSQL backup and restore runbook](../../../docs/runbooks/backup-and-restore-postgresql.md)
before changing this root.
