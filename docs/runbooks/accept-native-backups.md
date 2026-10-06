# Accept native backups before adoption

This is the JSON Keys **human-run acceptance procedure**, not authorization to provision or operate
cloud resources. Preparation may merge with every native path disabled. Approval of a live batch
names its exact targets, mutations, spending limit and stop conditions. Keep results in
[#190](https://github.com/a-novel/infra/issues/190); merging this procedure closes no adoption gate.

Exercise the current database VM → TLS repository VM → management-owned GCS path using the deployed
units. The [September single-VM result](../../proofs/pgbackrest-gcs/result-20260927.md) and
[offline proofs](../../proofs/pgbackrest/README.md) cover different boundaries. Do not recreate that
trial or substitute its simpler network, identity or entrypoint for this rehearsal.

## Shared-host activation

The approved shared-private deployment retains its existing database and logical backups.
It does **not** use the synthetic-source provisioning or destructive exercises below.
Do not recreate the retired per-service project or run fault injection on a serving database.

1. Bind the existing database group/member, preserved data-disk ID, repository host, attached
   identities and current image digest to fresh read-only evidence. Keep PostgreSQL, client,
   workers and repository on the exact deployed database artifact. Promote the same bytes to
   the service-specific registry; do not silently use the newer application release's database.
2. Settle issuer custody, names, validity, expiry notification and renewal/revocation before
   uploading numeric TLS versions. Keep the issuer key off both VMs, state and logs. A successful
   loader test is not an operational certificate lifecycle.
3. Through service foundation, prepare the repository runtime and exact image-reader grants.
   Start the existing micro only through its reviewed `active` setting. Verify the loaded
   image/certificates and TLS service; no database disk belongs to this root.
4. Through shared foundation, review `json_keys_native_backup` using the **existing protected
   database-maintenance** workflow. Require its fresh logical backup and clean restore check,
   same disks/addresses/capacity, no surge and no peer changes. The shared HCL renderer starts
   only the selected database; it does not activate native timers or expiration.
5. Keep initial WAL/backup verification attended. Prove exact identities, metadata isolation,
   authenticated repository access, stanza creation, archiving, a full/differential chain and
   an isolated SQL restore. Never restore over the serving disk. Obtain separate approval if
   the available isolation requires additional compute or recovery authority.
6. Before scheduling, prove the initial backup chain, isolated SQL restore, monitoring delivery
   and certificate rotation. A separately approved [coexistence pilot](#coexistence-pilot)
   can then collect scheduled outcomes and storage measurements while legacy protection remains.
   Full recovery and cost acceptance still govern adoption and legacy retirement.

### Review the shared-host maintenance commit

Startup-only maintenance replaces the JSON Keys instance template and recreates its existing
member with zero surge. The saved-plan gate requires `allow-resource-deletion` on the exact
planning commit's pull request **before merge**, even when every data disk is preserved. Review
that replacement scope with the pending protected configuration; adding the label after merge
cannot authorize the plan. The protected apply still requires its own saved-plan review.

Before publishing the opt-in, verify the repository over a pinned SSH host key: its attached
identity, image digest, active unit, TLS listener and certificate fingerprint must match the
reviewed inputs. Database operators need OS Login, IAP and Service Account User on the exact
repository identity. The shared foundation owns that account-level binding.

Keep the first `json_keys_native_backup.wal_archiving` value false. Reject a maintenance plan
that changes Authentication, a data disk, an address, a machine size or release metadata.
Bring-up leaves native backup timers stopped. Retain logical backups and snapshots through
acceptance; restart an approved pilot only after the reconciliation below.

Before stanza creation, verify PostgreSQL listens on both `/var/run/postgresql` and `/tmp`.
The native worker reaches the first socket through the shared `/run/agora/postgresql` mount;
the deployed image's local clients use the second. Require a successful SQL connection through
the worker's socket as well as a healthy database container. Repair a missing socket through
protected startup maintenance, then repeat this checkpoint before enabling WAL archiving.

Enroll the existing native policies through `shared_backup_alerts_enabled` in the JSON Keys
private service foundation: null leaves monitoring absent, false prepares disabled policies,
and true enables them. This reads the current singleton database group without taking host
ownership. Review a monitoring-only plan: one success metric and five policies using the existing
operations channel, with no host, disk, IAM or timer changes. Re-plan this scope after any database
replacement that changes its numeric instance ID. Never-seen backup/check success intentionally
alerts until the attended runs succeed; policy creation is not proof of notification delivery.
The data-disk policy uses COS used/free byte samples from the ext4 `noatime` mount configured by
database startup. Verify that mount's coverage after changes to the host filesystem configuration;
boot-disk samples alone do not satisfy the policy.

The hourly check first uses OpenSSL to verify the loaded client chain and the authenticated
repository chain at a date 30 days ahead. An expiring endpoint or issuer fails the existing check
unit and its failure alert; it does not disable full/differential backups or WAL archiving.
Inspect that unit's log to distinguish certificate renewal from an archive failure. No separate
certificate timer, exporter or cloud policy is required. This warning needs the check timer running;
before unattended adoption, run it manually and verify the current certificate metadata.

Renew before entering that 30-day window. Using the offline issuer, issue new endpoint keys and
certificates with the same approved names and purposes, then publish new numeric secret versions.
Review the exact version changes through protected foundation maintenance, retaining the data disk,
capacity and old versions for rollback. Stop consumers before changing their loaded credentials,
restart with the new versions and verify fingerprints, native authenticated access and a successful
check. Confirm old credential files are removed before disabling superseded secret versions.
For compromise, stop the affected endpoint and rotate trust/identities as required; disabling a
Secret Manager version alone does not revoke a PEM already loaded by a running process. Keep issuer
recovery custody separate from runtime and evidence; never upload its private key to either VM.

### Coexistence pilot

The JSON Keys pilot runs the existing full, differential and archive-check timers alongside logical
backups and snapshots. Automatic pgBackRest expiry and bucket lifecycle cleanup remain off.
Authentication is outside this pilot. Record dated approvals, exact identities, backup labels,
private evidence references and unresolved acceptance cases in #190; this runbook owns the procedure.

Use Cloud Logging and repository metadata for routine observation. The calendars are hourly at
`:30`, Monday–Saturday at `02:00 UTC` for differentials, and Sunday at `02:00 UTC` for full backups.
Allow five minutes of jitter, one minute of timer accuracy and the installed worker's runtime bound
(currently one hour) before calling a missing completion overdue. Investigate an explicit failure
immediately. A worker's successful exit and corresponding native catalog/WAL evidence establish an
outcome; a dispatched unit, synthetic event or manual run does not prove a scheduled deadline.

Timers are static and nonpersistent. Stopping the database stops its timers and workers; a reboot or
database restart does not resume timers or catch up missed runs. After protected maintenance:

1. Verify completion and guard release, the intended database system/data disk, healthy PostgreSQL
   and repository, loaded image/TLS versions, monitoring coverage and disk/WAL headroom.
2. Reconcile any interrupted worker before retrying. Run the existing archive check and inspect its
   completed result; retain historical backup labels and evidence.
3. With the pilot approval still applicable, start only `agora-backup-full.timer`,
   `agora-backup-diff.timer` and `agora-backup-check.timer`. Inspect their active/waiting states and
   next UTC deadlines. Do not add boot enablement or alter calendars to shorten observation.
4. Record the observation gap and resumption. Keep logical backups and snapshots active; a missed
   native run does not authorize changing retention, deleting objects or restoring over serving data.

The [cost worksheet](../costs/production.md#native-backup-coexistence) separates recurring native
cost, overlap and eventual savings. Successful scheduled runs do not prove independent-authority
recovery, source-loss recovery, later PITR or regional disaster recovery. Close those acceptance
limits explicitly before replacing legacy protection. Retirement also requires migrating every
release/maintenance consumer of the logical backup and restore-check jobs, retaining historical
readers/images until their supported recovery points expire, and a separate snapshot decision.

## Synthetic rehearsal boundary

The numbered sections below require separately approved synthetic resources and destructive targets.
They do not authorize moving, parking or damaging the serving shared-private deployment, recreating
retired proof projects, or expanding the coexistence pilot.

## 1. Approve the scope and cost

Start with the [operator preflight](README.md#start-an-operation). Record the following privately
before requesting the first live plan; publish only its sanitized review and evidence references.

| Approval field | Required binding                                                                                                                                                                                                                 |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Source         | Registered JSON Keys project **ID and number**, zone, state prefix, database group/disk and repository host. Confirm this is a new synthetic-only database, with no serving API, application writes or retained production data. |
| Custody        | Management project/bucket, native repository and distinct writer/recovery identities; current protected registration, input hashes and exact Git commit. Existing state must have one owner.                                     |
| Artifacts      | Published service and tooling SemVer inputs, resolved promoted digests, producer provenance, current scan review and PostgreSQL/pgBackRest compatibility. No floating tags or inherited trial exceptions.                        |
| Credentials    | Issuer custody, certificate names, expiry/renewal/revocation procedure and enabled numeric secret versions. Record metadata only; keep private keys off evidence/logs and the issuer off runtime hosts.                          |
| Recovery       | Fresh independently registered disposable project/number, source's service guard, independent PostgreSQL system ID and selected full/differential set. Record any cutoff before recovery.                                        |
| Execution      | Named operator and cleanup owner, attended host windows, synthetic data/size limit, maximum retained bytes, fault-injection scope, stop conditions and a separately priced attempt budget.                                       |
| Evidence       | Durable private location outside all test VMs/projects for state references, logs and checksums. Record each command's start/end, outcome and native identity; sanitize before sharing.                                          |

Use existing [foundation provisioning](provision-service-projects.md#protected-service-foundation-plans)
and [native recovery registration](../../environments/service-recovery/README.md#guarded-host-preparation).
These workflows authorize registered scopes, not arbitrary trial coordinates. Never repoint a
production registration, reuse an old trial project, or use `-target` to manufacture isolation.
If an approved synthetic source cannot be represented by the existing registration, stop for an
enrollment design; do not bypass the guard or create a parallel proof implementation.

### Cost worksheet

Before provisioning, price the saved plan with dated EUR rates for its exact region and billing
account. The recurring **additional** EUR 10–15/service/month ceiling is not a trial budget or an
instruction to spend that amount. Record gross replacement cost, temporary overlap and net steady
state at two, seven and ten services. Credit old costs only after resources and retention obligations end.

| Cost               | Quantity to measure and price                                                                                                                                                        |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Repository         | One e2-micro candidate and 20 GiB standard boot disk; use e2-small only after measured capacity failure and separate approval. No repository data disk, new NAT or public IP.        |
| Source             | The database VM, boot/data disks and existing daily snapshots during the rehearsal. These are real trial costs even where the future database host already belongs in the baseline.  |
| Recovery           | One bounded disposable attempt at a time; include VM hours, boot/data disks, private DNS and image storage through cleanup. Preserve failed evidence before replacing a destination. |
| Repository storage | Full/differential data, continuous WAL, copied consistency WAL, incomplete uploads, noncurrent versions and soft-deleted bytes over their actual retention windows.                  |
| Operations         | GCS requests/transfers, registry storage, Secret Manager, logs, metrics and alert evaluation; include shared-network charges attributable to the test.                               |

The source database/repository definitions have **no automatic trial shutdown deadline**. The recovery
host's four-hour limit covers one start only. Agree an attended stop window before starting anything;
export evidence and stop compute between stages and retention waits. Stopping VMs leaves billable
disks and other resources. [Billing alerts are not spending caps](https://docs.cloud.google.com/billing/docs/how-to/budgets).
Do not claim a monthly estimate from a few synthetic rows: record WAL/day, retained bytes by state,
backup/verify duration, peak memory, CPU and disk headroom under an agreed representative load.

## 2. Provision through existing owners

Use the future independent JSON Keys service project as the synthetic-only source. Its foundation
state remains the long-lived owner; only the independently registered recovery project is disposable.
This rehearsal does not authorize API cutover or retaining paid compute indefinitely. Record source
resources and their ongoing storage cost at closeout. Keep the current workload and both September
trial projects outside this enrollment.

Enroll in this order: review the exact service-project mapping and protected environments; create
the project shell; create the idle database/repository identities and hosts; then publish the
[repository network selection](provision-service-projects.md#native-repository-network-selection)
and review its separate shared-foundation plan. Leave application jobs, rotations and releases
absent. Prepare custody, artifact promotion and certificate versions before runtime configuration.
Each step retains its existing approval and saved-plan boundary.

Approve each private saved plan separately. Its allowed address set comes from the actual reviewed
plan, including prerequisite resources; there is no universal resource count. Reject peer changes,
legacy ownership transfer, unexpected replacements/deletions and public access.

| Owner                                      | Allowed purpose and checkpoint                                                                                                                                                                                                           |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Shared foundation                          | Selected project/agents, exact subnet access and [repository network rules](../../environments/production/foundation). No peer redeployment, public endpoint or new dedicated NAT.                                                       |
| Service foundation                         | Selected database/repository hosts and identities, image stores and operations channel. Initially keep runtime absent; confirm idle database and stopped repository, exact disk/VM IDs and effective permissions.                        |
| Management bootstrap                       | [Native bucket/roles](../../bootstrap/README.md#disabled-json-keys-native-backup-custody), then [TLS containers/grants](../../bootstrap/README.md#disabled-tls-credential-custody). Recovery stays disabled until its separate approval. |
| Protected publication and operator custody | Publish/promote reviewed artifacts, issue certificates and populate exact secret versions through their existing procedures. No package downloads or credential workarounds on a host.                                                   |
| Service foundation runtime                 | Install current units with `bring_up = false`, `wal_archiving = false` and `backup_alerts_enabled = false`. Convergence installs configuration; it establishes neither loaded boot configuration nor health.                             |

Reconcile inherited IAM, private DNS/routes, issuer custody and protected-environment permissions
before any consumer start. The repository process and authenticated database client share the accepted
backup-writer trust domain. Prove peer, policy and recovery boundaries without claiming server-readable
files or credentials are hidden from that client. Use synthetic probes, never credential extraction.

Bring up through the existing [guarded foundation operation](../service-operations.md#native-online-backups)
with its separately approved maintenance/bring-up gates. Hold admission through native reconciliation
and runtime readiness. Do not manually substitute `systemctl start` for this protected host operation.
Bring-up leaves timers off. Failed or uncertain commands retain admission; inspect the original work
before deciding how to reconcile it. `finish-operation` requires its existing completion evidence.

### Read-only host identity checkpoint

After bring-up, set the four exported `NATIVE_*` inputs below from the reviewed registration and
private post-apply evidence, in a fresh operator shell. The database instance **numeric ID** is not its
name. This example reads one host and rejects a mismatch; it does not prove runtime or network health.
Capture its output privately alongside the repository host's independently inspected identity.

```bash
bash <<'INSPECT'
set -euo pipefail
: "${NATIVE_SERVICE_PROJECT:?Set the approved JSON Keys project ID}"
: "${NATIVE_ZONE:?Set the approved zone}"
: "${NATIVE_DATABASE_INSTANCE:?Set the observed managed member name}"
: "${NATIVE_DATABASE_ID:?Set the approved numeric instance ID}"
: "${GCP_ACCOUNT:?Load the reviewed operator account}"
gcloud compute instances describe "$NATIVE_DATABASE_INSTANCE" \
  --project="$NATIVE_SERVICE_PROJECT" --zone="$NATIVE_ZONE" --account="$GCP_ACCOUNT" \
  --format='json(id,name,status,serviceAccounts.email,networkInterfaces.accessConfigs)' |
  jq -e --arg id "$NATIVE_DATABASE_ID" --arg name "$NATIVE_DATABASE_INSTANCE" \
    --arg identity "agora-database@${NATIVE_SERVICE_PROJECT}.iam.gserviceaccount.com" '
    select(.id == $id and .name == $name and .status == "RUNNING"
      and [.serviceAccounts[].email] == [$identity]
      and (.networkInterfaces | length == 1
        and all(.[]; (.accessConfigs // [] | length) == 0)))'
INSPECT
```

Inspect loaded units and bounded logs over approved IAP/OS Login access. Use selected `systemctl show`
properties (`LoadState`, `ActiveState`, `SubState`, `Result`, `ExecMainStatus`) and Docker
state/image/health fields; do not dump container environment, metadata payloads or secret files.

COS serves SSH keys from `/mnt/stateful_partition/etc/ssh`, not the temporary `/etc/ssh` keys
in cloud-init's automatic console report. Shared repository activation prints the persistent
ED25519 public-key fingerprint. Read it through the authenticated Compute Engine serial-output
API for the exact instance and boot, compare it with the IAP endpoint, and pin that key before
SSH access. Do not trust the unrelated cloud-init fingerprint or disable host-key verification.

### Park compute between attended windows

This procedure is limited to the synthetic source with no API traffic, application jobs or scheduled
rotations. Native group power commands do not acquire the service guard. The human operator must
hold an exclusive maintenance window; this is not a general production pause feature.

First approve and complete a protected service-foundation change from `database_runtime.bring_up = true`
to `false`, with native maintenance enabled and without bring-up. Confirm its quiescence evidence,
successful completion and guard release: timers/workers/database/repository stopped, no owned running
containers, repository VM `TERMINATED`. A no-op plan does not quiesce anything. Preserve failure
evidence and any held guard if this step is uncertain; do not proceed to manual power operations.

Before parking, close native workflow admission using the existing activation settings below. Record
their prior values and obtain explicit approval for the settings change. These flags are shared:
if another service uses them, stop for a service-scoped maintenance design instead of disabling it.
Leave the current production release flag and legacy backups unchanged.

| Protected entry point                         | Setting required during parking                                                                                                 |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Service-foundation plans/applies              | `SERVICE_FOUNDATIONS_ENABLED=false`                                                                                             |
| Application-job bootstrap                     | `SERVICE_JOB_BOOTSTRAP_ENABLED=false`                                                                                           |
| Native recovery preparation/execution/cleanup | `NATIVE_RECOVERY_PREPARATION_ENABLED=false`, `NATIVE_RECOVERY_EXECUTION_ENABLED=false`, `NATIVE_RECOVERY_CLEANUP_ENABLED=false` |
| Completion repair                             | `SERVICE_OPERATION_RECOVERY_ENABLED=false`                                                                                      |

Inspect effective repository/environment settings and queued, approval-waiting and running workflows.
Changing a flag does not revoke a run's captured inputs or stop accepted cloud work. Reconcile those
runs and their native operations before continuing. Withhold shared-foundation/bootstrap applies,
configuration publications and direct administrative writes throughout the window. Require an absent
service guard and no autoscaler on the selected group. Do not disable repairs or change group size
with `resize`.

Bind `NATIVE_DATABASE_GROUP` and its numeric `NATIVE_DATABASE_GROUP_ID` to the reviewed service
foundation output and live inspection. Reuse the source project, zone, instance name/numeric ID and
account from the identity checkpoint. Inspect the selected group before and after each power request:

```bash
bash <<'GROUP'
set -euo pipefail
: "${NATIVE_SERVICE_PROJECT:?}" "${NATIVE_ZONE:?}" "${GCP_ACCOUNT:?}"
: "${NATIVE_DATABASE_GROUP:?}" "${NATIVE_DATABASE_GROUP_ID:?}"
gcloud compute instance-groups managed describe "$NATIVE_DATABASE_GROUP" \
  --project="$NATIVE_SERVICE_PROJECT" --zone="$NATIVE_ZONE" --account="$GCP_ACCOUNT" \
  --format=json |
  jq -e --arg id "$NATIVE_DATABASE_GROUP_ID" --arg name "$NATIVE_DATABASE_GROUP" '
    select(.id == $id and .name == $name) |
    {id,name,targetSize,targetStoppedSize,targetSuspendedSize,status,currentActions}'
gcloud compute instance-groups managed list-instances "$NATIVE_DATABASE_GROUP" \
  --project="$NATIVE_SERVICE_PROJECT" --zone="$NATIVE_ZONE" --account="$GCP_ACCOUNT" \
  --format='json(instance,instanceStatus,targetStatus,currentAction)'
GROUP
```

After approval of the exact observed member, the human runs the native group command once:

```bash
gcloud compute instance-groups managed stop-instances "${NATIVE_DATABASE_GROUP:?}" \
  --instances="${NATIVE_DATABASE_INSTANCE:?}" --project="${NATIVE_SERVICE_PROJECT:?}" \
  --zone="${NATIVE_ZONE:?}" --account="${GCP_ACCOUNT:?}"
```

Google's [group stop operation](https://docs.cloud.google.com/compute/docs/reference/rest/v1/instanceGroupManagers/stopInstances)
changes running/stopped targets. Request completion precedes member convergence. Read-only inspection
must establish exactly the original member, `targetStatus=STOPPED`, `instanceStatus=TERMINATED`,
`currentAction=NONE`, stable group status and counts **running 0, stopped 1, suspended 0**. Recheck its
numeric VM ID and the repository's stopped state. Unknown outcomes require inspection, not resubmission.
Keep the admission settings closed and do not apply OpenTofu while parked: HCL still declares one
running member. Record stop time and retained disks, snapshots, registry and storage costs.

For a separately priced resume window, recheck the same parked identities/counts and absent guard.
Keep admission closed while the human runs `gcloud compute instance-groups managed start-instances`
with the same group, member, project, zone and account arguments. Verify the original member is
`RUNNING`, target `RUNNING`, action `NONE`, group stable, and counts **running 1, stopped 0, suspended 0**.
Confirm the loaded native units and containers remain stopped and the repository VM remains stopped.
Host power alone is not database bring-up.

Only then review restoration of the admission settings needed for the next batch and generate a
fresh protected plan. Reject unexpected replacement, drift or peer changes. Resume runtime through
guarded foundation bring-up; backup timers require their separate health reconciliation and approval.
No old saved plan or failed power request is replayed. These observations need live evidence before
the pause/resume procedure is accepted for use beyond this rehearsal.

## 3. Establish protection, then scheduling

Enable `database_runtime.backup_alerts_enabled` through its reviewed foundation plan before WAL
activation. Confirm the five policies use the selected VM ID and real operations channel. First
prove notification delivery and data-disk telemetry; absence of incidents is not evidence. A
monitor-only apply must leave hosts and timers unchanged. Keep observers active throughout the drill.

In the approved synthetic database, exercise the actual service image's bootstrap, extensions and
schema/migrations through the existing service-owned path. Record the system ID independently from
the source, and [capture the application fingerprint](#capture-independent-application-data) before
each backup. An `initdb`-only fixture cannot
prove application recovery. Migration failure needs inspection, not replay.

Request WAL activation through guarded foundation maintenance only after disk/notification coverage
works. Create the stanza using the installed `agora-backup-stanza-create.service`, then run
`agora-backup-check.service` and `agora-backup-full.service` in that order, waiting for each native
command and its container to finish. A successful `systemctl start` dispatch is not job completion.
Inspect retained logs plus pgBackRest `info`; preserve set, database epoch/system ID, WAL bounds and
copied consistency WAL. Use `agora-backup-diff.service` after another recorded commit, and
`agora-backup-verify.service` to inspect the complete native integrity report. Exit zero alone does
not establish integrity, especially for an empty repository.

After first-backup, recovery and monitoring evidence is accepted, separately approve starting the
installed full/diff/check timers. They have no `[Install]` section: do not use `enable --now` or add
boot targets for this rehearsal. Confirm their UTC deadlines and no-catch-up behavior. Shutdown stops
them; restart does not resume them. Resumption requires explicit database/repository/backup health
reconciliation. Do not change production calendars to shorten an observation window and call that
a real deadline test.

### Capture independent application data

Keep synthetic application writers, rotations and migrations quiesced from capture until the full
or differential backup completes. Run the fixed [data.sql](../../internal/recovery/data.sql) from
the same reviewed commit as the recovery image, against the independently checked source host.
It hashes all eight persisted `public.keys` fields, including encrypted private keys and nulls,
in UUID order with UTC timestamps. Only one SHA-256 leaves PostgreSQL. The clock-dependent
`active_keys` view is excluded. PostgreSQL owns [serialization](https://www.postgresql.org/docs/18/functions-json.html)
and [hashing](https://www.postgresql.org/docs/18/functions-binarystring.html); no extra extension is needed.

From the reviewed infra checkout, reuse the `NATIVE_*`/`GCP_ACCOUNT` inputs from the identity
checkpoint. Set `NATIVE_EVIDENCE_DIR` to the existing private evidence directory outside all test
projects. This command only reads source data; a failed or malformed observation is not an expectation.

```bash
bash <<'CAPTURE'
set +x
set -euo pipefail
umask 077
set -C
: "${NATIVE_SERVICE_PROJECT:?}" "${NATIVE_ZONE:?}" "${NATIVE_DATABASE_INSTANCE:?}"
: "${GCP_ACCOUNT:?}" "${NATIVE_EVIDENCE_DIR:?}"
capture_dir="$(mktemp -d "$NATIVE_EVIDENCE_DIR/data.XXXXXXXX")"
gcloud compute ssh "$NATIVE_DATABASE_INSTANCE" \
  --project="$NATIVE_SERVICE_PROJECT" --zone="$NATIVE_ZONE" --account="$GCP_ACCOUNT" \
  --tunnel-through-iap --ssh-key-expire-after=1h \
  --command='sudo -n timeout 40s docker exec -i --user=postgres agora-postgres-json-keys psql -XqAtw -v ON_ERROR_STOP=1 -h /var/run/postgresql -U agora_json_keys -d agora_json_keys -f -' \
  < internal/recovery/data.sql > "$capture_dir/candidate.txt"
mapfile -t fingerprint < "$capture_dir/candidate.txt"
[[ ${#fingerprint[@]} == 1 && ${fingerprint[0]} =~ ^[a-f0-9]{64}$ ]] ||
  { printf 'STOP: incomplete fingerprint; retain diagnostics.\n' >&2; exit 1; }
mv -- "$capture_dir/candidate.txt" "$capture_dir/expected_data_sha256.txt"
printf 'PASS: source fingerprint saved in %s\n' "$capture_dir"
CAPTURE
```

After native backup completion, bind that file to its exact set, independent system ID, source
numeric VM ID, observation/backup times and reviewed commit in private evidence. Resume writers
only after that association is recorded. Before recovery preparation, set `verify_sql = true` and
`expected_data_sha256` to that file's value in the protected recovery input. Never derive it from
the recovered destination or update it to match a failed restore.

An empty table has a valid fingerprint: use meaningful, independently known synthetic rows for
the rehearsal. This is a small-table comparison, bounded by the existing container memory and
30-second query/five-minute worker limits; aggregation uses 32 bytes per row plus query overhead.
Timeouts or resource exhaustion fail the attempt. It does not prove a concurrent production
snapshot, decryption with application secrets, later PITR, or API compatibility.

## 4. Acceptance matrix

Run one reviewed fault at a time with a healthy positive control before and after. Mark each row
**pass, fail or not run**, with private evidence references. Stop progression on failure; never turn
missing evidence into a pass. Destructive rows require their exact synthetic targets to be approved.

| Case                               | Evidence required for acceptance                                                                                                                                                                                                                                                         |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Identity and network               | Own-service operations work from the actual containers. Database metadata/host-gateway and peer paths fail; repository peer buckets, policy changes and recovery authority fail for the intended permission. Include effective inherited IAM, attachment and host/container controls.    |
| TLS and boot                       | Exact promoted images and loaded configuration; successful native authenticated repository read. Wrong trust/identity, unavailable secret and expiry fail closed without consumer start. Exercise renewal and removal of loaded old credentials with stopped consumers.                  |
| Backup chain                       | Real full → changed rows → differential, WAL archival and complete integrity report. Preserve expected SQL independently of the backup catalog. Measure durations, stored bytes and WAL growth.                                                                                          |
| Isolated recovery                  | Use protected `plan-native`, `apply-native`, then `restore-native` with approved `RESTORE-SQL` selection. Require copied WAL, networkless paused SQL checks, expected application rows and stopped PostgreSQL/VM plus private completion. A files-only result is insufficient.           |
| Interruption                       | Interrupt a real upload and maintenance/start/restore at meaningful boundaries, including a lost acknowledgement. Preserve partial objects/attempts; prior usable backups stay usable. Unknown outcomes hold admission and cannot be replayed.                                           |
| Process and host failure           | Database stop stops timers/workers and all owned containers; jobs cannot start a stopped database. Exercise repository/Docker/host outage and bounded WAL growth, loaded configuration after reboot, and explicit reconciliation. No automatic timer resume is assumed.                  |
| Source loss and writer containment | After explicit synthetic host/disk-loss approval, recover without the original data disk. Establish old writer credentials are unusable with effective-access evidence; account disable alone is insufficient. Recover under independent recovery authority.                             |
| Dependency damage                  | Separately remove/corrupt a still-required bundle, mutable catalog and WAL generation. Native verification/restore must detect the loss. Repair only reviewed generations under independent recovery authority, then repeat SQL recovery with the approved selection.                    |
| Retention and expiry               | Follow [native expiry acceptance](backup-and-restore-postgresql.md#native-expiry-acceptance), including retention denial, partial catalog mutation, retained-chain SQL recovery and explicit reconciliation. Inventory live/noncurrent/soft-deleted bytes.                               |
| Notification                       | Actual worker failure, integrity error/empty report, archive failure, stopped host, never-seen/missing success, disk pressure/missing telemetry and weekly deadline produce the intended notification. Record event, incident and delivery timestamps; calendar closure is not recovery. |

Data-fidelity acceptance requires the independently captured `expected_data_sha256` in the prepared
request and the matching `data_sha256` in stopped SQL completion. Missing expectations retain
schema-only behavior and leave this acceptance gate unproven. A mismatch retains the failed attempt
and service guard; reconcile it without changing expectations, replaying or promoting the database.

The guarded recovery path currently verifies **backup consistency**, not later PITR or API cutover.
Record PITR beyond that point as unproven by this workflow; do not use the old manual proof to claim
the new execution boundary supports it. Recovery selections and limitations belong in the acceptance
decision. After soft-delete repair, the original repository-time cutoff can still fail because restored
objects get new generations/timestamps. Preserve that failure; an explicit-set comparison needs separate
approval and a fresh destination, never an automatic fallback.

Capture total operator RTO separately from automated restore duration, and RPO from the last recovered
committed data relative to the simulated loss. Compare with the currently accepted recovery objectives;
do not infer them from backup frequency. Test Authentication independently before extending approval
beyond JSON Keys.

## 5. Close the rehearsal and decide adoption

Export evidence before stopping or deleting its only copy. Inventory every created resource, grant,
image and object generation against the approved plans; reconcile partial operations first.

| Boundary                           | Cleanup decision                                                                                                                                                                                                                                                                                  |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Source hosts                       | Quiesce through protected maintenance: timers, workers, archiver/database, repository. Confirm no owned containers remain. Stop compute explicitly; never stop just a MIG member and assume it stays stopped. Source disk/IP, snapshots, registry and boot disks survive as their owners specify. |
| Source resources                   | Retain or remove only with an exact reviewed ownership/cleanup plan. Existing `prevent_destroy`/deletion guards are intentional. No blanket foundation destroy, management-project deletion or recovery-cleanup shortcut for the source. Record retained cost and owner.                          |
| Recovery project                   | After completed/exported evidence and revoked cross-project access, use [guarded cleanup](../../environments/service-recovery/README.md#guarded-project-cleanup). Failed/uncertain attempts need reconciliation first. `DELETE_REQUESTED` is not permanent erasure or settled billing.            |
| Management storage and credentials | Retain backup generations, state, evidence, receipts and reservations. Revoke temporary grants and reconcile credential retirement without affecting current readers. Review storage cleanup only after actual retention/soft-delete inventory permits it.                                        |

Keep all legacy protection through a separate adoption decision. Record measured gross/net EUR cost,
retention liabilities, resource headroom, RPO/RTO, passed cases and unresolved limits. Only accepted
native protection authorizes a separate PR retiring the selected logical writer/jobs and redundant
tooling. Historical readers/images remain until their supported points expire; snapshots have their
own cost/recovery-value decision. This procedure creates no recurring trial or cleanup automation.

Primary references: [pgBackRest operations](https://pgbackrest.org/user-guide.html),
[systemd timers](https://github.com/systemd/systemd/blob/v257/man/systemd.timer.xml),
[GCS soft deletion](https://docs.cloud.google.com/storage/docs/soft-delete).
