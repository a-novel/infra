# Back up and restore PostgreSQL

> First production run: the step-6 release creates and proves the recovery jobs before traffic;
> step 7 verifies that evidence and locks retention through a separate reviewed change.

This runbook operates the logical PostgreSQL backups, clean restore drills, and crash-consistent
disk snapshots for JSON Keys and Authentication. It is the recovery procedure for database data;
application rollback does not rewind schemas or rows.

The resources are defined but are not deployed yet. Merging their definitions creates nothing. Do
not run a mutating command in this runbook until the management, foundation, and release workflows
exist on `master`, their protected GitHub environments are configured, and a maintainer has
explicitly authorized the first production apply.

Google product behavior is documented by [Cloud Run jobs](https://cloud.google.com/run/docs/create-jobs),
[Cloud Run ephemeral disk](https://cloud.google.com/run/docs/configuring/jobs/ephemeral-disk),
[Cloud Storage retention policies](https://cloud.google.com/storage/docs/bucket-lock),
[Cloud Storage lifecycle rules](https://cloud.google.com/storage/docs/lifecycle),
[scheduled Persistent Disk snapshots](https://cloud.google.com/compute/docs/disks/about-snapshot-schedules),
and PostgreSQL's [`pg_dump`](https://www.postgresql.org/docs/18/app-pgdump.html) and
[`pg_restore`](https://www.postgresql.org/docs/18/app-pgrestore.html) references.

## Operator context

Paste this block once before selecting or invoking a recovery job:

```bash
set -euo pipefail
set +x
umask 077

REPOSITORY='a-novel/infra'
REGION='europe-west1'

MANAGEMENT_PROJECT_ID="$(gh variable get GCP_MANAGEMENT_PROJECT_ID --repo "$REPOSITORY")"
WORKLOAD_PROJECT_ID="$(gh variable get GCP_WORKLOAD_PROJECT_ID --repo "$REPOSITORY")"
MANAGEMENT_PROJECT_NUMBER="$(gcloud projects describe "$MANAGEMENT_PROJECT_ID" \
  --format='value(projectNumber)')"
BACKUP_BUCKET="${MANAGEMENT_PROJECT_ID}-${MANAGEMENT_PROJECT_NUMBER}-backups"
```

## Recovery objectives

| Objective           | Contract                                                                                                                                            |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Logical-backup RPO  | At most six hours. Each database is dumped every four hours with a 30-minute job timeout.                                                           |
| Logical-restore RTO | Measure every drill against 90 minutes. The automated restore job fails after 60 minutes so the target is missed before the objective is exhausted. |
| Logical retention   | Six restore points per day for 14 days: 84 attempts per database, subject to successful completion.                                                 |
| Snapshot retention  | One crash-consistent data-disk snapshot each day at 02:00 UTC, retained for seven days.                                                             |
| Production writes   | Forbidden until both first logical backups and both clean restore drills succeed.                                                                   |

A logical dump is the primary portable recovery point. A disk snapshot is a faster, crash-consistent
host recovery point and does not replace a tested logical restore. Point-in-time recovery is
deliberately deferred until one of the thresholds in [Escalate to PITR](#escalate-to-pitr) is met.

## Implemented topology

The release root creates five scale-to-zero Cloud Run jobs and five Cloud Scheduler entries when
both database recovery contracts are enabled:

| Job                                     | UTC schedule   | Purpose                                                                        | Maximum runtime |
| --------------------------------------- | -------------- | ------------------------------------------------------------------------------ | --------------: |
| `agora-postgres-backup-json-keys`       | `15 */4 * * *` | Dump JSON Keys and commit its completion manifest.                             |      30 minutes |
| `agora-postgres-backup-authentication`  | `45 */4 * * *` | Dump Authentication and commit its completion manifest.                        |      30 minutes |
| `agora-postgres-restore-json-keys`      | `15 3 1 * *`   | Restore the newest committed JSON Keys backup into a fresh local cluster.      |      60 minutes |
| `agora-postgres-restore-authentication` | `45 3 1 * *`   | Restore the newest committed Authentication backup into a fresh local cluster. |      60 minutes |
| `agora-postgres-backup-monitor`         | `5 * * * *`    | Check both manifests, RPO, object sizes, and retained bytes.                   |       5 minutes |

Cloud Scheduler authenticates with `agora-scheduler-invoker`; that account receives only
`roles/run.jobsExecutor` on these exact jobs. Scheduler starts an execution and does not wait for it. The
native Cloud Run completion metric therefore remains authoritative: one condition detects failed
executions and another detects three hours without a completed hourly monitor.

The foundation root also attaches `agora-database-daily-snapshots` to the preserved `agora-data`
disk. The schedule stores snapshots in `europe-west1` for inexpensive fast local recovery and keeps
them after source-disk deletion. Portable logical backups remain in the management project's EU
multi-region bucket for regional-loss recovery.

## Backup commit protocol

Each backup job uses the exact promoted database image digest. This keeps `pg_dump`, `pg_restore`,
the declared owner, extensions, and schema bootstrap at the same PostgreSQL major as production.

The database container writes a custom-format, zstd-compressed archive to an ephemeral volume and
refuses to continue unless all of these checks pass. Disk-backed `emptyDir` is a Cloud Run Preview
feature; backup and restore declare the `BETA` launch stage and use its supported 10 GiB minimum so
no quota increase is required. Retries, checksums, and monthly clean restores are the acceptance
controls for this early-product tradeoff.

- the archive is non-empty and `pg_restore --list` can read it;
- `pg_dump` emitted no warning or diagnostic;
- the source project, private host, port, database, owner, execution, and tool version match the
  hardcoded contract;
- the running PostgreSQL server reports the same immutable database-image digest and PostgreSQL
  major as the backup container; an upgrade ordered ahead of its source backup therefore fails
  closed instead of publishing a mislabeled recovery point;
- no undeclared non-system role, role membership, database, tablespace, extension, or replication
  slot exists; the current contract contains only `plpgsql` and `uuid-ossp` extensions;
- the dedicated backup role is login-capable, non-privileged, and a member of
  `pg_read_all_data`.

A stock curl sidecar uploads the archive to a unique attempt path with
`ifGenerationMatch=0`, then uploads the 18-line `completed.manifest`. The manifest is the commit
record: an archive without that marker is never restorable. It records identifiers, source identity,
image and tool versions, timestamps, size, and SHA-256 only—never credentials or row data.
The non-root sidecar can read the root-owned `0444` files but cannot replace them: its only writable
path is a separate write-only control directory used for the fixed success/failure signal.

The host supplies the digest as the `agora.database_image` command-line startup marker. PostgreSQL
explicitly accepts namespaced [custom two-part options](https://www.postgresql.org/docs/18/runtime-config-custom.html),
so this consistency check needs no extension, table, file, or additional process. It detects an
accidentally reversed deployment order under trusted host administration; image promotion and
digest pinning remain the authenticity controls.

Objects use this layout:

```text
v1/<database>/attempts/<started-epoch>-<execution>-<attempt>/database.dump
v1/<database>/attempts/<started-epoch>-<execution>-<attempt>/completed.manifest
```

The bucket rejects public access, uses uniform IAM, prevents deletion, disables soft delete, keeps
every object for at least seven days, and deletes objects after 14 days. Soft delete is intentionally
off: retaining another billable hidden copy after lifecycle deletion would duplicate the reviewed
retention policy.

## Security boundaries

| Identity                  | Data it can reach                                                                                                       | Deliberately cannot do                                                                                                                           |
| ------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `agora-backup`            | Read the two exact backup-password secrets; connect privately to both PostgreSQL ports; create new backup objects.      | List, read, overwrite, or delete backup objects; administer databases; use an owner credential; reach the public internet.                       |
| `agora-restore`           | Read backup objects and supported restricted Google APIs.                                                               | Reach either production PostgreSQL port; read a secret; create, overwrite, or delete a backup; reach the public internet.                        |
| `agora-scheduler-invoker` | Invoke the five exact recovery jobs.                                                                                    | Read backups or secrets; connect to a database; alter a job.                                                                                     |
| `infra-release`           | Define the jobs and schedules; invoke the five exact recovery jobs during release verification; list snapshot metadata. | Run a job with overrides; create or delete a snapshot; read backup objects or secret payloads; change bucket retention, network, or project IAM. |

Cloud Run jobs expose no request endpoint. All task traffic enters the deny-by-default VPC. Backup
tasks receive the `agora-backup` tag, which allows only restricted Google APIs and the two private
PostgreSQL ports. Restore and monitor tasks receive `agora-restore`, which allows restricted Google
APIs but has no database egress rule. Production PostgreSQL still has no external address, public
frontend, public DNS record, or public firewall path.

The backup role in each cluster is separate from its owner. It has `LOGIN`, `INHERIT`,
`pg_read_all_data`, and a connection limit of two; it has no superuser, database creation, role
creation, replication, or row-security bypass authority. The host creates and rotates that role from
the exact backup-password version in release metadata. All four owner and backup passwords must be
distinct.

## Preconditions and stop conditions

Stop before any production mutation unless all of these statements are true:

- the bootstrap and foundation runbooks have completed and their verification records are clean;
- the protected foundation and release workflows exist on `master` and require their documented
  GitHub environment approvals;
- `production-json-keys-postgres-backup-password` and
  `production-authentication-postgres-backup-password` each have an enabled numeric version created
  through [the secret-version runbook](./secret-versions.md);
- those values are distinct from one another and from both database-owner passwords;
- both database images have been promoted to the production Artifact Registry with an immutable
  digest and use the same PostgreSQL major as their source clusters;
- the release input enables Authentication and JSON Keys together and pins both numeric backup
  secret versions;
- the alert notification channel is verified, and a named operator can receive its messages;
- no incident, restore, migration, foundation apply, or second database release is already active.

Do not use `latest`, a tag-only image, a branch image, a public database address, an owner password
for backups, or a local `tofu apply` as a shortcut.

## Select and verify the deployed boundary

Run the following only from a private, non-recorded operator shell. These commands inspect metadata;
they do not print secret values or backup payloads.

```bash
[[ "${MANAGEMENT_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "${WORKLOAD_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "${REGION}" =~ ^[a-z]+-[a-z]+[0-9]+$ ]]

[[ "${MANAGEMENT_PROJECT_NUMBER}" =~ ^[0-9]+$ ]]

gcloud storage buckets describe "gs://${BACKUP_BUCKET}" \
  --format='yaml(name,location,storage_class,public_access_prevention,uniform_bucket_level_access,soft_delete_policy,retention_policy,lifecycle_config)'
```

Expected safe result: the bucket is `STANDARD` in `EU`, public access prevention and uniform access
are enabled, soft-delete retention is zero, object lifecycle age is 14 days, and bucket retention is
seven days. Before the first successful clean restore, `isLocked` is false. After the lock step below,
it is true permanently.

Verify the jobs and schedules without exporting their full environment or embedded scripts:

```bash
gcloud run jobs list \
  --project="${WORKLOAD_PROJECT_ID}" \
  --region="${REGION}" \
  --filter='metadata.name:agora-postgres-' \
  --format='table(metadata.name,metadata.labels.role)'

gcloud scheduler jobs list \
  --project="${WORKLOAD_PROJECT_ID}" \
  --location="${REGION}" \
  --filter='name:agora-postgres-' \
  --format='table(name.basename(),schedule,timeZone,state)'
```

Expected safe result: exactly the five jobs and five enabled UTC schedules in the topology table.
If either count or any schedule differs, stop and reconcile the reviewed OpenTofu state; do not patch
the live resource with `gcloud`.

## First production activation

The first empty host is the only exception to “dump before changing a database”: there is no source
database to dump. It is not an exception to snapshot, restore, or no-production-writes requirements.

1. Apply bootstrap and foundation only through their approved workflows, then prepare the reviewed
   production manifest and release configuration.
2. Wait for the foundation-owned daily snapshot schedule to produce a `READY` `agora-data` snapshot.
   Google starts the 02:00 UTC schedule during the 02:00–02:59 window. The gate opens only after the
   snapshot is `READY` and closes six hours after its actual creation, no later than roughly 09:00
   UTC. Missing that window means waiting for the next scheduled snapshot; do not grant release
   permission to create one.
3. Dispatch the protected release. The pre-change helper recognizes the empty release revision,
   validates the fresh scheduled snapshot, and skips logical backup because no cluster exists yet.
   The fixed release graph then activates both clusters, runs migrations, creates both logical
   backups, proves both clean restores, and runs `agora-postgres-backup-monitor` before the manual
   initializer gate or any service traffic.
4. Verify both clusters and their four distinct credentials through the PostgreSQL host runbook,
   and verify that the successful private receipt records all five recovery execution names.
5. Record completion times, image digests, and the two selected manifest attempt identifiers in the
   private recovery record. Never copy a dump, secret, full job definition, or raw log into GitHub.
6. Lock bucket retention through a separately reviewed code change as described in
   [Lock retention after proof](#lock-retention-after-proof).

If any step fails, keep application writers disabled. Correct the declared image, secret version,
IAM, network, or schema contract in code and restart from the first failed step. Never mark an
incomplete archive as completed or bypass a failed smoke test.

## Execute an immediate logical backup

Use this before the first write, as an operator-confirmed recovery point, or when diagnosing a
schedule. The protected database release and migration paths invoke the same jobs automatically.

```bash
for job in \
  agora-postgres-backup-json-keys \
  agora-postgres-backup-authentication; do
  gcloud run jobs execute "${job}" \
    --project="${WORKLOAD_PROJECT_ID}" \
    --region="${REGION}" \
    --wait \
    --quiet \
    --format='yaml(metadata.name,status.conditions,status.startTime,status.completionTime)'
done
```

Expected safe result: each execution completes successfully within 30 minutes. A successful task has
already uploaded a non-empty archive and its completion manifest. The command intentionally does not
stream application logs.

Independently list committed markers and their object metadata without downloading payloads:

```bash
for database in json-keys authentication; do
  gcloud storage ls --long \
    "gs://${BACKUP_BUCKET}/v1/${database}/attempts/**/completed.manifest" \
    | tail -n 1
done
```

Expected safe result: one recent, non-zero completion manifest for each database. Treat the output as
private operational metadata because it contains attempt identifiers. If an execution succeeded but
no marker exists, declare the backup failed, inspect its private Cloud Run logs, and do not fabricate
or upload a marker manually.

## Run and measure a clean restore

The restore job selects only the newest completion manifest, requires an exact 18-key schema,
requires the exact workload project, private source address, database port, image, and PostgreSQL
major, copies the archive to ephemeral storage, checks size and SHA-256, and runs
`pg_restore --exit-on-error --single-transaction` into a newly
initialized local cluster. The cluster listens only on a Unix socket and receives no production
credential. Hardcoded service schema and integrity smoke checks must pass before success.

```bash
DRILL_STARTED_EPOCH="$(date -u +%s)"

for job in \
  agora-postgres-restore-json-keys \
  agora-postgres-restore-authentication; do
  gcloud run jobs execute "${job}" \
    --project="${WORKLOAD_PROJECT_ID}" \
    --region="${REGION}" \
    --wait \
    --quiet \
    --format='yaml(metadata.name,status.conditions,status.startTime,status.completionTime)'
done

DRILL_COMPLETED_EPOCH="$(date -u +%s)"
DRILL_SECONDS="$((DRILL_COMPLETED_EPOCH - DRILL_STARTED_EPOCH))"
test "${DRILL_SECONDS}" -le 5400
printf 'Both PostgreSQL clean restores completed in %s seconds.\n' "${DRILL_SECONDS}"
```

Expected safe result: each job succeeds in less than 60 minutes and the combined operator-observed
drill remains within the 90-minute RTO. Record both execution names, start/completion times,
duration, source attempt identifiers, image digests, operator, and outcome in the private recovery
record.

On failure, do not retry blindly. Classify the fixed error category in private logs:

- missing or stale manifest: investigate the backup job, scheduler, IAM, and RPO alert;
- image or PostgreSQL-major mismatch: retain the older image and run its matching restore contract;
- size, checksum, or archive-list failure: quarantine that attempt and use the prior completed one
  only through a reviewed recovery change;
- `pg_restore` or service smoke failure: treat the current backup as unproven, block migrations and
  production writes, and repair the schema or backup contract in code;
- timeout: measure archive size and restore phases, then follow the PITR/scaling thresholds instead
  of extending every timeout without evidence.

## Pre-change recovery gate

`ops/prepare-database-change.sh` is mandatory before every database image update and every migration.
It is called automatically by `ops/deploy-database-release.sh`. A migration workflow must call it
before the migration job and must not duplicate its checks.

For an existing cluster, run the gate while the deployed backup jobs still use the current source
image digests. Only after both source backups succeed may the host move to the new images; reconcile
the recovery jobs to those new digests after the new clusters are healthy. Reversing that order
fails closed because a backup job refuses a server-reported image marker that differs from its own.

The gate:

1. requires the exact seven-key foundation/release metadata map;
2. finds the newest foundation-scheduled snapshot with the exact disk, labels, regional location, and
   `READY` state;
3. rejects a snapshot older than six hours or more than five minutes in the future;
4. for a non-empty database release, executes both logical backup jobs synchronously;
5. exits before any database metadata or migration can change.

The release identity can list snapshots but cannot create or delete them. With one daily snapshot,
planned database changes therefore occur after the 02:00–02:59 UTC scheduler window and until six
hours after the actual snapshot creation time. This deliberate window avoids an on-demand snapshot
controller and a second snapshot lifecycle.

A service-only or platform-only deployment does not need a new dump. Its protected workflow must run
`agora-postgres-backup-monitor` and require success, proving both committed backups are at most six
hours old before traffic changes:

```bash
gcloud run jobs execute agora-postgres-backup-monitor \
  --project="${WORKLOAD_PROJECT_ID}" \
  --region="${REGION}" \
  --wait \
  --quiet \
  --format='yaml(metadata.name,status.conditions,status.startTime,status.completionTime)'
```

## Lock retention after proof

Locking a Cloud Storage retention policy is irreversible. After it is locked, it cannot be removed
or shortened; only an increase is allowed. Do this once, only after both first clean restore jobs
succeed and their private recovery record is reviewed.

1. Open a dedicated pull request changing only `google_storage_bucket.backups.retention_policy` in
   `bootstrap/storage.tf` from `is_locked = false` to `is_locked = true`.
2. Confirm the sanitized plan changes one bucket in place, with no replacement or deletion.
3. Obtain the protected foundation approval and apply the exact reviewed plan from `master`.
4. Verify independently:

```bash
gcloud storage buckets describe "gs://${BACKUP_BUCKET}" \
  --format='yaml(name,retention_policy,soft_delete_policy,lifecycle_config)'
```

Expected safe result: the retention period remains 604800 seconds, `isLocked` is true, soft delete
remains zero, and lifecycle age remains 14 days. Never use a direct bucket-lock command as a shortcut;
the irreversible desired state and review evidence belong in Git.

## Verify least privilege

Inspect allow policies without requesting or printing access tokens:

```bash
gcloud storage buckets get-iam-policy "gs://${BACKUP_BUCKET}" \
  --format=json \
  | jq --exit-status \
      --arg backup "serviceAccount:agora-backup@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" \
      --arg restore "serviceAccount:agora-restore@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" '
        def roles_for($member): [.bindings[] | select(.members | index($member)) | .role] | sort;
        (roles_for($backup) == ["roles/storage.objectCreator"]) and
        (roles_for($restore) == ["roles/storage.objectViewer"])
      '
```

Expected safe result: `true`. Also verify no user-managed keys exist:

```bash
for account in agora-backup agora-restore agora-scheduler-invoker; do
  gcloud iam service-accounts keys list \
    --iam-account="${account}@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" \
    --project="${WORKLOAD_PROJECT_ID}" \
    --managed-by=user \
    --format='value(name)'
done
```

Expected safe result: no output. Any user-managed key is an incident: disable it, determine its use,
remove it through the approved response, and verify WIF/runtime authentication before resuming.

## Later cross-project recovery acceptance

The monthly jobs prove the archive against a fresh cluster but run in the production workload
project. The epic's final recovery-acceptance task,
[`a-novel/.github#277`](https://github.com/a-novel/.github/issues/277), owns one additional restore
in a newly created, disposable preproduction project. That later exercise proves recovery does not
depend on the workload project's IAM or network. It is a one-time human recovery exercise, not a
permanent fourth OpenTofu root or an always-on environment.

Use a dedicated reviewed recovery change and the `production-recovery` approval. The temporary
project must have its own billing link, Cloud Run service agent, and keyless runtime account. Copy
the already deployed restore job through the Cloud Run v2 API after removing production VPC access
and replacing its service account. Grant the temporary runtime read-only access to the backup bucket
and grant the temporary Cloud Run service agent read-only access to the exact production Artifact
Registry repository. Do not copy a backup password or owner password: the restore job needs neither.

Do not perform that exercise during this task: its reviewed command set cannot be validated until
the production jobs exist. Task #277 must add the exact project creation, API-copy, execution,
evidence, IAM-revocation, and project-deletion commands using the then-current Cloud Run v2 export
schema. A maintainer must compare the copied job's image digest, embedded restore script hash,
read-only bucket mount, lack of secrets, and lack of VPC access with the deployed production job
before execution.

Stop rather than improvising if that reviewed command set is absent. This protects against silently
copying output-only fields or production service-account/VPC references as Google evolves the API.
The monthly clean-room jobs in this task establish routine recoverability; task #277 closes the
separate cross-project acceptance requirement.

## Alerts and routine review

`Agora PostgreSQL recovery jobs unhealthy` has two conditions on Cloud Run's native completion
metric: any failed `agora-postgres-*` execution, or no completed
`agora-postgres-backup-monitor` execution for three hours. Together they cover:

- backup failure, missing completion marker, or the 30-minute backup duration ceiling;
- restore absence, checksum/catalog mismatch, restore/smoke failure, or the 60-minute duration
  ceiling;
- an RPO older than six hours;
- a missing, malformed, or mismatched completion manifest;
- total retained backup objects above 250 GiB, leaving cost headroom below the USD 20/month design
  gate after EU write replication and one monthly restore read;
- a stopped monitor schedule or dispatch path that produces no monitor execution.

The absence condition starts only after the first successful monitor measurement; first activation
therefore executes the monitor explicitly. Metric absence is not resource-deletion protection, so
the reviewed deletion-label gate remains the control for removing the monitor or its schedule.

The hourly monitor reads object metadata and manifests but never database payloads. After any alert:

1. acknowledge only after a named operator owns the incident;
2. freeze database changes and, if RPO is exceeded, nonessential production writes;
3. inspect the failed execution privately and identify the fixed error category;
4. execute a manual backup only after correcting the cause;
5. run both clean restores when integrity, image compatibility, or retained data is in doubt;
6. record actual RPO, restore duration, retained bytes, resolution, and whether a PITR threshold was
   crossed.

Review monthly restore executions every month even when no alert fires. Cloud Scheduler acceptance
only proves that the API request was accepted; the Cloud Run execution result proves the restore.
During the same review, run the non-mutating inventory in
[Authentication synthetic health](./respond-to-alerts.md#authentication-synthetic-health) and
confirm the scheduled workflow is active, its owner is current, and its last health job is newer
than six hours. This catches GitHub's public-repository inactivity disablement without a second
monitor.

## Storage forecast

Four-hour cadence over 14 days retains at most 84 completed logical archives per database, plus
small manifests and any incomplete attempt objects until lifecycle deletion. Use:

```text
retained logical GiB = 84 × aggregate compressed GiB of one JSON Keys + Authentication backup
logical USD/month ≈ (84 × 0.026 + 180 × 0.02 + 1 × 0.02) × aggregate compressed GiB
                  ≈ 5.80 × aggregate compressed GiB
```

The formula includes steady EU multi-region Standard storage, about 180 aggregate writes per
30-day month, and one aggregate monthly read into `europe-west1`. A combined 2 GiB current set
retains about 168 GiB and costs about USD 11.60/month before partial attempts. The 250 GiB monitor
threshold corresponds to about a 3 GiB current set and roughly USD 17.30/month. Track incomplete
attempts and same-region snapshot delta storage separately. The hourly monitor measures all retained
logical objects rather than estimating from only completed archives.

## Escalate to PITR

Open a PITR design epic when any one condition is measured:

- a logical backup exceeds 30 minutes;
- a clean restore exceeds 60 minutes;
- one current compressed backup set exceeds 20 GiB in aggregate;
- logical-backup storage exceeds USD 20/month;
- the business requires an RPO below six hours; or
- a managed database or backup commitment becomes acceptable.

That epic must compare WAL archival, managed PostgreSQL, restore sequencing, encryption/key recovery,
retention, monitoring, and the measured operator burden. Do not bolt continuous WAL shipping onto
these jobs without that design.

## Cleanup

Clear operator-shell identifiers when the procedure finishes:

```bash
unset MANAGEMENT_PROJECT_ID MANAGEMENT_PROJECT_NUMBER WORKLOAD_PROJECT_ID REGION BACKUP_BUCKET
unset DRILL_STARTED_EPOCH DRILL_COMPLETED_EPOCH DRILL_SECONDS
```

Do not manually delete an archive, manifest, snapshot, schedule, job, bucket, or IAM binding. A
planned deletion belongs in a reviewed pull request and requires the repository's explicit
resource-deletion label gate. Locked retention can still postpone an approved object deletion.
