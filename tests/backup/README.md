# Backup integration tests

Offline tests that run inside the production database image, with no network and synthetic data.
They prove the parts this repository owns:

- the restore worker (`internal/recovery`) and its offline SQL check;
- in `modules/database-runtime/files`, the startup script's collation step, application role
  convergence and fail-closed steps, and `check-backup.sh`'s TLS checks;
- backup and restore through a mutually authenticated TLS repository, and its client and stanza
  denials.

Run them from the repository root, in the image of a service with native backups: `json-keys`,
`authentication` or `genai`. The offline SQL test runs that service's case.

```bash
SERVICE=json-keys
podman build -f builds/backup-test.Dockerfile --build-arg DATABASE_SERVICE="$SERVICE" \
  -t "backup-test:$SERVICE" .
podman run --rm --network=none --read-only --tmpfs=/tmp:rw,size=1g,mode=1777 \
  "backup-test:$SERVICE"
```
