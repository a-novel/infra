# JSON Keys database runtime

This resource-free module renders the existing native PostgreSQL/pgBackRest units
for both foundation owners. It owns no VM, disk, identity, secret version or schedule
activation. Roots validate image provenance inputs, identity selection and placement.

- `cloud_config` prepares the dedicated-project host without starting its units.
- `startup_script` starts the database on the shared foundation's existing stateful
  host, through its protected maintenance path. COS recreates the configuration at boot.
- Both outputs use the same database unit, credential loader, pgBackRest configuration,
  bounded workers and disabled timers. PostgreSQL remains isolated from instance credentials.

The database metadata image must have the same digest as `repository.server_image`;
registry copies may use different paths. The supervised entrypoint rejects a mismatch
before starting PostgreSQL. Keep client, workers and repository on that same artifact:
this opt-in is not a PostgreSQL or pgBackRest upgrade.

See [shared-host activation](../../docs/runbooks/accept-native-backups.md#shared-host-activation)
for the maintenance boundary and the checks that rendering configuration cannot establish.
