# Operate the private PostgreSQL host

This runbook verifies and maintains the separate one-member stateful managed instance groups for
JSON Keys and Authentication PostgreSQL. It covers private isolation, capacity, controlled
replacement and native recovery.

Inspection requires an authorized operator. Mutations use reviewed protected workflows;
there is no supported local `tofu apply` path.

## Operator context

Load the committed operator defaults before every local command:

```sh
. ./.envrc
go run ./cmd/infra verify-env --github
```

Host discovery, inspection, and SSH are stateless commands documented in
[Debug the private PostgreSQL host](./debug-postgresql-host.md).

## Apply boundary

Merging, validating, or planning this repository creates nothing, and there is no supported local
apply command. Foundation and release changes may be applied only by manually dispatching their
protected workflow from the reviewed `master` commit.

Stop before every mutating step unless all of these controls exist on `master`:

1. the management plane and remote state are applied and verified;
2. the protected foundation and release workflows authenticate through their exact Workload
   Identity Federation providers;
3. each workflow stores its opaque saved plan only in private Google Cloud storage and prints only
   the sanitized action/resource-type summary;
4. the matching GitHub environment requires a reviewer, rejects administrator bypass, and prevents
   self-review unless the bootstrap runbook's solo-maintainer exception is active;
5. OpenTofu applies only the reviewed, unexpired plan from the merged commit; the database maintenance
   step invokes only the reviewed native proof and host helper; both paths prove convergence afterward.

The inspection commands below become available after those workflows create the host. They do not
authorize an operator to change a VM, group, disk, firewall, metadata, or secret with `gcloud`.

### Review startup-template maintenance before planning

The shared startup script is part of both immutable database templates. A startup-only
correction can replace both templates and their template-scoped release IAM bindings, then update
both managed groups' template targets. It must preserve the data disks, stateful addresses, runtime
identities, image selections, secret versions, and resource sizes.

Before dispatching the foundation plan, check the merge queue and refresh clean `master`. The PR
whose merge commit is now `master` must have received `allow-resource-deletion` from a human
maintainer before merging. Approval on an earlier PR does not carry forward through an intervening
merge, even when that merge changes only tooling or documentation. A label added after merge does
not authorize that commit. If approval is missing, prepare a maintenance PR describing the pending
replacement scope and obtain the label before merging it. Recheck this boundary whenever `master`
moves.

Keep `PRODUCTION_RELEASES_ENABLED=false` and use the
[protected foundation plan](./provision-workload-foundation.md#4-apply-the-workload-foundation).
Review the complete fresh plan; a documentation-only PR does not make unapplied infrastructure
changes disappear. Stop for unrelated resource actions or changes to the preserved properties above.
The label permits the plan's deletion gate; the exact saved-plan apply still requires separate
approval. Template application leaves these opportunistic groups' running members unchanged.
For startup-only replacements, use the protected path below. Other host changes still require a
separately reviewed maintenance implementation. Verify the running hosts adopted the corrected
startup script before approving a production release retry.

### Database image collation changes

PostgreSQL 18 images can use different libc or ICU sorting-library versions even when the
PostgreSQL version is unchanged. Before publishing a database port, startup checks the selected
image against the existing cluster in a short-lived, network-isolated container on the same host.
It uses the existing data disk and CPU/memory allocation; it adds no cloud resource.

For the application database, `postgres` and `template1`, a version mismatch rebuilds ordinary
user-table indexes before refreshing named and default collation versions. Each database's
rebuild and refresh share one transaction. A failed rebuild cannot mark that database reconciled.
The same preparation runs when rollback selects the previous image. No database is dropped or
reinitialized, and native recovery proof remains required.

This is not a general schema migration: materialized views, partitioned or foreign tables, and
stored generated columns stop preparation for a separately reviewed migration. Review the actual
schema and available disk headroom before changing the sorting library. Preparation is limited to
120 seconds (plus a 15-second forced-stop grace), inside the existing startup budget. A timeout or
SQL error leaves the normal database container stopped; retain the maintenance hold and investigate
instead of refreshing versions manually or accepting a warning-bearing backup.

### Protected database maintenance

This path is disabled unless the protected foundation environment has
`LEGACY_DATABASE_MAINTENANCE_ENABLED=true` and `PRODUCTION_RELEASES_ENABLED=false`. Enabling it,
approving the exact saved-plan apply, accepting downtime, and later retrying a release are separate
human decisions. Leave it unset during ordinary operation. Do not dispatch a release concurrently.

The selected service must have `native_backups[SERVICE].wal_archiving=true` and a running,
service-owned repository. Foundation's IAP access is restricted to each enrolled database's private
address and SSH port; repository access is owned by its service foundation.

The existing foundation `apply` operation inspects the saved plan before consuming it. A startup
change accepts only template replacements, their template IAM and group target changes. Both hosts are selected when the shared
startup script changes. Images, credential versions, data disks, machine sizes, network configuration
and stateful preservation rules remain unchanged. Unrelated managed-resource actions block admission.

The protected operation:

1. Captures the current template, singleton, data and boot disk identities, private address, release metadata and
   healthy boot. Creates a private, create-only maintenance hold, then consumes the reviewed plan.
2. Applies and checks convergence of the template targets.
   The verified `OPPORTUNISTIC` policy leaves running members alone. Newly granted IAM may need
   propagation; permission failure stops the operation, never authorizes an unchecked replacement.
3. Runs the selected database's native archive check and full backup. The helper independently reads
   its PostgreSQL system identifier, selects only the full backup completed during this operation,
   and restores that exact set on the existing service-owned repository VM. A networkless SQL
   container must reach paused recovery consistency and verify the expected identity and schema.
   The database is never promoted. Scratch capacity and CPU/memory are bounded; insufficient
   capacity or uncertain execution retains the hold. Successful proof removes its scratch copies.
4. Rechecks the original host and boot, then updates that exact member with `REPLACE`/`RECREATE`,
   zero surge and one unavailable member. Verifies a new boot disk incarnation and healthy boot on the
   same data disk and private address, with the reviewed template, image, identity and secret-version
   metadata. Google may retain the VM ID during recreation; that ID alone is not a replacement
   signal. It stops at the first failure; it does not continue to the peer or roll back automatically.
5. Writes private completion evidence, including the native backup label, system identity, SQL verification and old/new host
   identities, before deleting only its acknowledged hold generation.

Native proof uses the existing database and repository capacity. It adds no cloud resource.
Backup storage and API requests incur normal usage charges.

The hold is `gs://<state-bucket>/release/legacy-maintenance/operation.json`. Completion evidence is
under `release/legacy-maintenance/completions/<hold-generation>.json` in the same private bucket.
Foundation applies and native service releases refuse an existing or unreadable hold. A lost
runner, failed backup, failed convergence or uncertain replacement leaves it in place. Do not rerun
the consumed plan, adopt the hold, clear it speculatively, or run `update-instances` by hand.

For interrupted maintenance, keep releases paused. First establish that the original workflow and
Google operations are no longer running, then compare the exact hold generation and any completion
record against each group's live member, template, disk, address, release metadata and health.
Use the separately enabled recovery path below only when the applied foundation has converged and
each host is either still on its original template or provably completed the recorded replacement.
Other partial states require investigation, not a generic unlock or retry.

After successful verification, turn off `LEGACY_DATABASE_MAINTENANCE_ENABLED`. Independently verify
client connectivity and the applicable release prerequisites before approving a production retry.
Completion of maintenance does not re-enable releases.

### Change one database image

Foundation owns each group's image digest, revision and numeric credential versions through
`database_releases`. Before adopting an existing fleet, populate **both** entries from verified live
group metadata; an empty map is only for a fleet that has never started. Preserve every unrelated
foundation input. Establish a zero-change plan before selecting a new image, and never reset a
populated fleet to the empty default.

For an image transition, change only one entry's promoted database digest and reviewed revision.
Verify producer provenance, PostgreSQL compatibility and the collation preparation above. Use the
same protected maintenance activation, saved-plan review and hold as startup maintenance. Admission
rejects mixed template/image work, a second database transition, credential rotation or any disk,
capacity or network change.

After applying the group's metadata, the running member remains unchanged under `OPPORTUNISTIC`.
The helper requires the same fresh native backup and isolated SQL restore, then rechecks the
original healthy boot. It applies the metadata to that exact
member with both the minimum action and disruption ceiling set to `RESTART`. Completion requires
the same VM, boot disk, data disk, private address and template, with the new image/revision and a
new healthy boot. A failed safety check leaves the original member running and retains the hold;
an uncertain restart also retains the hold. Never replay its consumed plan.

### Reconcile interrupted maintenance

After reviewing the exact retained hold and original failed run, a human may separately enable
`LEGACY_DATABASE_RECOVERY_ENABLED=true` in `production-foundation`. Keep maintenance enabled and
production releases explicitly paused. From clean, current `master`, use the inspected hold's
numeric generation, not a plan ID:

```sh
go run ./cmd/infra foundation recover-legacy "${MAINTENANCE_HOLD_GENERATION:?}" "RECOVER LEGACY ${MAINTENANCE_HOLD_GENERATION:?}"
```

This is a protected foundation dispatch with the usual approval and global writer serialization.
It does not replay the consumed plan, apply infrastructure, alter IAM, or enable releases. It requires
the current protected foundation configuration to converge with applied state before touching hosts.
It verifies the hold's workload scope and original workflow identity, and rejects an active or rerun
original writer. A completed run is not by itself evidence that its hosts completed maintenance.

For an image-only hold, recovery is read-only: the exact original VM and disks must already run the
reviewed metadata with a new healthy boot, and its last start must fall within the original workflow
interval. Recovery never retries the restart. An image hold that failed before restart needs a
separately reviewed reconciliation.

For each host, the helper verifies the stable singleton, preserved data disk and address, exact
release metadata, runtime identity, sizing, subnet and reviewed startup template. A host already on
the new template is skipped only with a new healthy guest boot and a boot disk created within the
original operation's interval, from hold creation through workflow completion. When the hold includes
the old boot disk ID, that ID must differ too. Older holds can use the bounded disk creation time;
they never require the VM ID to change. A pending host must retain its original instance and healthy
boot; its boot disk is captured before fresh native backup and isolated SQL restoration. Only pending
hosts run that proof and undergo replacement. All hosts are rechecked before completion.

Before native proof or replacement, a create-only record is stored at
`release/legacy-maintenance/recoveries/<hold-generation>.json`. After host verification, the workflow
publishes the converged foundation configuration, writes completion evidence, then deletes only the
acknowledged hold generation. Uncertain admission, replacement, publication or completion retains
the recovery record and prevents automatic replay. Do not delete either record or rerun the original
apply to bypass a failure; reconcile the exact evidence through a separately reviewed operation.

After success, disable both maintenance flags. Release activation and retry still need independent
approval and client-connectivity verification. Recovery creates no additional VM or recurring job;
native proof for pending hosts incurs normal storage and request charges.

## Operating limits and inspection

There is one private singleton database VM and preserved data disk per service repository.
JSON Keys listens on private port 5432 and Authentication on 5433. Both remain single-zone:
host maintenance or zone loss interrupts the affected database. A managed replacement preserves
data but cannot repair corruption. There is no autoscaler or health-driven repair loop.

Native pgBackRest owns WAL archiving, weekly full backups, daily differentials and hourly checks.
The database systemd lifecycle starts and stops its timers. Chain-aware expiry and object-store
retention jointly constrain removal; never bypass retention or delete the last verified recovery
chain. Follow [native backup acceptance](./accept-native-backups.md) and the
[recovery runbook](./backup-and-restore-postgresql.md) for exact-set verification.

```sh
go run ./cmd/infra database inspect authentication
go run ./cmd/infra database inspect json-keys
```

Require a stable singleton, unchanged preserved disk/address, no public interface, reviewed runtime
identity and firewall rules, and the capacity and native-backup alerts. Check client health as well
as the container; successful template application alone does not prove adoption by a running host.
The [debug runbook](./debug-postgresql-host.md) covers IAP, OS Login and private diagnostics.

## Capacity, credentials and failures

- Measure CPU, memory, filesystem headroom and connection counts without collecting application
  rows or credential payloads. Review cost and quota before changing machine or disk capacity.
- COS image, sizing, disk growth and credential rotation are not accepted by the startup-only or
  image-only maintenance admissions above. Each needs a reviewed implementation and exact saved
  plan; never use a manual VM/group update to evade those limits.
- Preserve the original disk on mount failure. Do not format, detach, run filesystem repair, or
  recreate it speculatively. Restore damaged data only through the protected native recovery path.
- An uncertain replacement or failed startup keeps its maintenance hold. Inspect the original
  workflow, host identity, boot and private evidence before using the recovery operation. Never
  replay a consumed plan or clear a guard merely because the runner stopped.
- Image rollback is another reviewed one-service image transition with native recovery proof.
  It does not roll back SQL migrations or data. Coordinate credential changes with all consumers;
  [secret-version handling](./secret-versions.md) owns delayed destruction.
- IAP remains the only SSH path. Do not introduce public database access, temporary external IPs,
  NAT, service-account keys or container egress to work around diagnosis failures.
- Keep passwords and TLS keys in their established private runtime/Secret Manager boundary,
  never in public logs, metadata, plan output, shell arguments or Git.

The existing `legacy-maintenance/` custody namespace and activation-variable names identify
retained operation evidence; they do not enable the removed logical-backup or release machinery.
