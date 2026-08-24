# Operational runbooks

This directory holds operator procedures for deployment, rollback, secrets, backups, restore, and
clean-room recovery as those capabilities land.

Each runbook states its prerequisites, the exact command, safe expected output, an independent verification, and the recovery path for a partial failure. Commands that can change production name the required GitHub environment approval and never place a secret value on the command line.

Available procedures:

| Runbook                                                                      | Use it for                                                                                                                               | Do not use it for                                                                          |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| [Bootstrap and verify the management plane](./bootstrap-management-plane.md) | The one-time project, billing, local-state apply, GCS migration, GitHub environment, IAM, WIF, audit, and broad-access-removal sequence. | Routine changes or an agent-run apply.                                                     |
| [Add or rotate a secret version](./secret-versions.md)                       | Hidden double-entry through stdin, numeric-version rollout, disable/re-enable, delayed destruction, and audit.                           | Secret container metadata, GitHub secrets, or printing a payload to verify it.             |
| [Recover a prior state generation](./state-recovery.md)                      | A corrupt or incorrect live GCS state generation after writers are frozen and recovery is approved.                                      | Ordinary application rollback or reconciling resources without a separately reviewed plan. |

The root README's [Setup](../../README.md#setup) section links the entry point and repository-only
validation. PostgreSQL backup, workload rebuild, and application rollback runbooks land with the
resources they operate; the existence of the protected backup bucket alone is not presented as a
working backup system.
