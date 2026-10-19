# database-runtime

Renders the boot configuration of a database host with native backups: its PostgreSQL and backup
systemd units, its pgBackRest client configuration and its backup timers.

`files/` holds the host scripts, which every database host runs.
