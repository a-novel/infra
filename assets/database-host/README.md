# Database host startup assets

`startup.sh` prepares the preserved service disk and owner credential. Its `--supervise` mode runs
under systemd with native TLS backups; initial boot prepares an idle host until release metadata is
complete. Both foundation roots use this adapter and `shutdown.sh`.

Startup changes replace immutable instance templates. Apply them through a reviewed protected
maintenance plan with native backup and restore verification; merging code alone does not update a
running host. File ownership checks use `stat -c`, supported by GNU and BusyBox images.
