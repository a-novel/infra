# database-runtime

Renders a database host's boot configuration:

- the PostgreSQL and backup systemd units;
- the pgBackRest client configuration and its TLS loader;
- the backup timers.

`files/` holds the host scripts that the units run.
