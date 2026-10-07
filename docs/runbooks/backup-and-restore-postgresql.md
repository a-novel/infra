# Back up and restore PostgreSQL

JSON Keys and Authentication use separate pgBackRest repositories in management-owned storage.
Each database archives WAL from its existing private VM and runs bounded native backup workers.
Application rollback does not rewind database schemas or rows.

## Routine protection

| Unit                       | UTC schedule          | Purpose                                          |
| -------------------------- | --------------------- | ------------------------------------------------ |
| `agora-backup-full.timer`  | Sunday 02:00          | Start a full backup.                             |
| `agora-backup-diff.timer`  | Monday–Saturday 02:00 | Start a differential backup.                     |
| `agora-backup-check.timer` | Hourly at :30         | Check archive delivery and certificate lifetime. |

Timers allow five minutes of random delay plus one minute of accuracy. They do not catch up missed
runs. When scheduling is enabled in the reviewed runtime configuration, the database service starts
and stops its timers with its own lifecycle. A stopped database stays stopped when a backup is
requested. Workers have a one-hour runtime limit, share pgBackRest's native lock and leave bounded
logs for diagnosis.

Confirm the selected service, source instance ID, PostgreSQL system ID, repository and immutable
image before running an operation. Use [private host access](./debug-postgresql-host.md); do not open
a public database or SSH port.

## Run an attended backup

On the selected, healthy database host, run the installed `agora-backup-check.service`, followed by
`agora-backup-full.service` or `agora-backup-diff.service`. Wait for each worker to finish before the
next step. A successful start request does not prove successful backup completion.

Inspect the unit result, retained container logs and pgBackRest catalog. Record the exact set label,
database epoch/system ID, completion time, WAL bounds and copied consistency WAL. Run
`agora-backup-verify.service` to inspect the native integrity report; an empty repository or exit zero
alone is insufficient. Preserve diagnostics before another run replaces the exited container.

A manual run proves that operation, not a natural calendar firing. Record the trigger accurately.
Do not change schedules just to manufacture scheduled-success evidence.

## Restore and maintenance

Use the [disposable recovery procedure](./disaster-recovery.md) for an independent exact-set restore,
including compatible image selection, fresh storage, isolated SQL verification and cleanup.
Schema verification and an independently captured application-data fingerprint establish different
properties; record which was checked. Neither authorizes traffic cutover.

Protected database maintenance takes a fresh native full backup and verifies that exact set through
networkless SQL on the existing repository host before replacing the database host. Follow
[database maintenance](./operate-postgresql-host.md) and
[service admission](../service-operations.md#native-online-backups). Do not replace a held operation
with a direct apply or silently select another backup after failure.

## Retention and costs

Reviewed native retention expires complete full/differential chains through pgBackRest. Storage
versioning, retention and soft delete can preserve billable generations after native expiry.
Inspect live, noncurrent and soft-deleted bytes separately; deleting a catalog entry does not prove
storage reclamation. Never use an age-only lifecycle rule against live native backup dependencies.

The accepted operating configuration uses a 14-day full-chain window. This is not a guarantee that
every point remains recoverable: verify the actual catalog, dependencies and restore evidence.
Changing retention, enabling noncurrent cleanup or deleting historical copies requires an exact
review. Locked retention cannot be shortened to accelerate approved retirement.

Track repository/WAL growth, retained generations, requests, networking and logs against the approved
per-service allowance. Short acceptance runs do not establish long-term monthly cost.
Follow [native backup alerts](./respond-to-alerts.md#native-backups) for missed runs, archive failure,
disk pressure and certificate warnings.

## Native backup preparation

New services stay disabled until separately approved. Follow the
[bootstrap custody contract](../../bootstrap/README.md#service-owned-native-backup-custody),
[repository host contract](../../environments/service-foundation/README.md#optional-stopped-repository-host)
and [acceptance procedure](./accept-native-backups.md). Review the exact storage, TLS identities,
network access, host capacity and cost before provisioning. Empty secret containers do not issue
certificates or grant approval to upload them.

Establish effective own-repository access and peer denials, disk and notification coverage, valid
numeric certificate versions, and recoverable full/differential sets before enabling continuous
writes and schedules. Keep native recovery preparation/execution disabled outside an approved
attempt. Never infer live acceptance from mocked tests.

### Native expiry acceptance

Use a separately approved synthetic repository and the deployed image/transport/retention policy.
Keep automatic expiry and noncurrent cleanup disabled for new services until their evidence is
accepted. Existing production acceptance does not authorize destructive experiments on its copies.

1. Preserve a private catalog and generation inventory with retained-byte totals and dependency
   chains. Verify the selected retained sets through SQL.
2. Inspect native dry-run expiry, then execute only the reviewed expiry. Preserve exit status,
   catalogs and generation inventories even on failure: failure is not proof of rollback.
3. Distinguish live-to-noncurrent transitions from generation deletion denied by retention. Record
   the exact denied operation; do not weaken retention. Reconcile partial expiry explicitly and
   verify retained full/differential sets through SQL.
4. After separate lifecycle approval, verify only eligible noncurrent generations enter soft delete.
   Allow lifecycle lag and measure retained storage by state; elapsed age is not hard-deletion proof.
5. Test an explicitly selected historical view after exact-generation repair. Keep any failed
   original cutoff as evidence instead of silently advancing it.

Do not invent catalog repair or replay an unexpected expiry. Preserve evidence and review the
failure before proceeding.

## Retirement

Resource deletion uses a reviewed saved plan and the repository's deletion-approval gate.
Preserve the last verified native recovery copies. Separately inventory historical objects and
snapshots, remove only the approved eligible copies, and record retention-blocked leftovers until
they can be removed. Never weaken locked retention or erase private recovery evidence.
