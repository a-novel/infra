# Operational runbooks

This directory holds operator procedures for deployment, rollback, secrets, backups, restore, and clean-room recovery as those capabilities land.

Each runbook states its prerequisites, the exact command, safe expected output, an independent verification, and the recovery path for a partial failure. Commands that can change production name the required GitHub environment approval and never place a secret value on the command line.

The repository bootstrap actions currently required from an operator live in the README's [Setup](../../README.md#setup) section.
