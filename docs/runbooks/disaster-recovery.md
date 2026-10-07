# Recover a native PostgreSQL backup

Recover one service at a time into an isolated disposable project using the
[protected native recovery workflow](../../environments/service-recovery/README.md).
JSON Keys and Authentication each retain their own database identity and repository.
Recovery never mounts or changes the serving database disk.

## Select and approve the attempt

Record the source service, independently verified PostgreSQL system ID, exact completed
pgBackRest set, compatible immutable restore image and any repository-time cutoff.
Use the [native acceptance procedure](./accept-native-backups.md) to capture an independent
application-data fingerprint when data-fidelity verification is required. Schema checks alone
do not prove that all application data was recovered.

Approve the disposable project's resource inventory, cost allowance and cleanup deadline before
provisioning. A stopped VM still incurs disk and DNS charges. Include every production and
management project in the protected-project set; none is a valid recovery destination.

## Prepare, restore and verify

Follow [guarded preparation](../../environments/service-recovery/README.md#guarded-host-preparation)
and [file restoration](../../environments/service-recovery/README.md#guarded-file-restoration).
Preparation, execution and cleanup remain separately disabled until approved.

The reviewed saved plan prepares a stopped private host. The restore operation checks the exact
fresh data disk, restores the selected set, and verifies its database identity. Optional SQL
verification runs with no network and PostgreSQL paused at that backup's consistency point.
Success includes confirmed PostgreSQL and host shutdown.

A files-restored result is not SQL verification. Neither result authorizes traffic cutover,
source fencing or point-in-time recovery beyond the selected backup. Review those decisions
separately before serving recovered data.

An interrupted or failed attempt must not be replayed. Preserve its records and use the
[operation inspector](../service-operations.md#inspect-an-interrupted-apply) to reconcile the
exact held operation before approving another destination.

## Clean up the disposable project

Export private evidence, inspect the whole disposable project, and revoke its temporary
cross-project access. Then follow
[guarded project cleanup](../../environments/service-recovery/README.md#guarded-project-cleanup)
with the exact project number and completed restore generation.

Cleanup deletes only the approved disposable project. Keep management-owned backups, retained
state/evidence and permanent attempt reservations. Verify deletion and eventual billing settlement;
a deletion request is not proof of permanent erasure. Restore temporary policy exceptions and reset
the cleanup authorization after the attempt.
