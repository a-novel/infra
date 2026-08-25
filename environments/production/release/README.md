# Production release root

This root owns routine, manifest-driven application deployment. It selects exact container digests,
runs one-shot jobs, creates service revisions, shifts traffic, and records the release state used for
application rollback. Durable project, IAM, network, disk, snapshot, bucket-retention, and monitoring
policy stay in bootstrap or foundation state.

## State and authority

The protected release identity uses the isolated `release/` backend object. It may manage Cloud Run
jobs and Cloud Scheduler entries, attach the three foundation-owned recovery identities, and set the
invoker policy on release-owned jobs. It cannot change project IAM, VPC policy, remote-state
protection, the preserved database disk, snapshot lifecycle, backup retention, or secret payloads.

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

Release deployment follows the fixed database → services → platform order and restores the prior
receipt if a health gate fails. Backward-compatible migrations remain applied; restoring database
contents is a separate recovery operation.

## Current status

The root defines PostgreSQL backup, restore, freshness, and storage-monitoring jobs for JSON Keys and
Authentication. Recovery resources are created only when `database_releases` enables both databases
as one unit. Both application components remain disabled in the production image manifest.

No protected release workflow exists yet, so the root has no authenticated caller and cannot be
applied from GitHub or an operator checkout. Merging or validating this code creates no Cloud Run
execution, Storage object, scheduler entry, or other cloud resource.

## Resource inventory

The provider is pinned in [`versions.tf`](./versions.tf). The links explain Google Cloud behavior a
maintainer must understand; ordinary OpenTofu syntax is not repeated.

| OpenTofu address                                     | Agora purpose and boundary                                                                                                                                                                                                                                                         | Lifecycle, recovery, and cost                                                                                                                                                                                                        | References                                                                                                                                                                                                                                                                                                                                        |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `google_cloud_run_v2_job.postgres_backup`            | Two scale-to-zero, single-task jobs use the exact promoted database images to create custom-format logical dumps. Each job mounts one exact numeric backup-password version and writes only to an ephemeral shared volume.                                                         | Jobs retry once and time out after 30 minutes. The database image uses 1 vCPU/1 GiB; the stock uploader sidecar uses 1 vCPU/512 MiB. Jobs have no ingress. Their resource deletion is covered by the repository deletion-label gate. | [Provider job resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job), [Cloud Run jobs](https://cloud.google.com/run/docs/create-jobs), [multi-container jobs](https://cloud.google.com/run/docs/create-jobs#multi-container), [`pg_dump`](https://www.postgresql.org/docs/18/app-pgdump.html) |
| `google_cloud_run_v2_job.postgres_restore`           | Two monthly jobs mount the backup bucket read-only, validate the newest committed manifest and SHA-256, then restore into a fresh local cluster with the matching database image and hardcoded service smoke checks. They receive no secret and have no production-database route. | Jobs do not retry and time out after 60 minutes. Each uses 2 vCPU/4 GiB plus a 16 GiB ephemeral disk only while running. A failed restore cannot mutate production.                                                                  | [Provider job resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job), [Cloud Storage volume mounts](https://cloud.google.com/run/docs/configuring/jobs/cloud-storage-volume-mounts), [`pg_restore`](https://www.postgresql.org/docs/18/app-pgrestore.html)                                    |
| `google_cloud_run_v2_job.postgres_backup_monitor`    | One hourly job checks both completion manifests, the six-hour RPO, matching archive size, and all retained logical-backup bytes without reading row payloads.                                                                                                                      | It retries once, times out after five minutes, and fails above 700 GiB retained bytes. That failure feeds the native recovery-job alert and leaves headroom below the USD 20/month storage threshold.                                | [Provider job resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job), [Cloud Run job monitoring](https://cloud.google.com/run/docs/monitor-jobs)                                                                                                                                              |
| `google_cloud_run_v2_job_iam_member.*_scheduler`     | Grants the foundation-owned scheduler identity `roles/run.invoker` on only these five release jobs.                                                                                                                                                                                | Additive bindings expose no public or user invoker. Release uses a two-permission custom foundation role to set job IAM without Cloud Run Admin. IAM has no fixed charge.                                                            | [Provider job IAM resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_run_v2_job_iam), [Cloud Run IAM roles](https://cloud.google.com/run/docs/reference/iam/roles)                                                                                                                                    |
| `google_cloud_scheduler_job.postgres_backup`         | Starts JSON Keys at minute 15 and Authentication at minute 45 every four hours using OAuth as the exact scheduler identity.                                                                                                                                                        | One API retry handles transient dispatch failure. Scheduler acceptance is not execution success; the Cloud Run metric remains authoritative. Scheduler is usage-priced with a small free allowance.                                  | [Provider scheduler resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_scheduler_job), [authenticated HTTP targets](https://cloud.google.com/scheduler/docs/http-target-auth)                                                                                                                         |
| `google_cloud_scheduler_job.postgres_restore`        | Starts both clean restore drills on the first day of each month at 03:15 and 03:45 UTC.                                                                                                                                                                                            | Monthly scale-to-zero execution measures recoverability without a permanent staging cluster. A failed execution alerts and never reaches production PostgreSQL.                                                                      | [Provider scheduler resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_scheduler_job), [Cloud Scheduler overview](https://cloud.google.com/scheduler/docs/overview)                                                                                                                                   |
| `google_cloud_scheduler_job.postgres_backup_monitor` | Starts the recovery monitor at minute 5 every hour.                                                                                                                                                                                                                                | The hourly cadence detects a missed four-hour backup before the six-hour RPO is exceeded for long.                                                                                                                                   | [Provider scheduler resource](https://registry.terraform.io/providers/hashicorp/google/7.45.0/docs/resources/cloud_scheduler_job), [Cloud Scheduler overview](https://cloud.google.com/scheduler/docs/overview)                                                                                                                                   |

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
- exact foundation-owned backup, restore, and scheduler service-account emails;
- both promoted database image digests and both positive numeric backup-password versions.

`database_releases` is empty by default and must contain exactly `authentication` and `json_keys`, or
neither. Enabling one database alone fails validation. Images must match the exact production
Artifact Registry repository in the selected project and region.

Outputs contain only job and schedule names. They contain no secret version, credential, source
manifest, bucket payload, or billing value.

Read the [architecture](../../../docs/architecture.md),
[Google Cloud provider guide](../../../docs/google-cloud.md),
[cost worksheet](../../../docs/costs/production.md), and
[PostgreSQL backup and restore runbook](../../../docs/runbooks/backup-and-restore-postgresql.md)
before changing this root.
