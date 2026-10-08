# Backup integration tests

Offline tests that run inside the production database image, with no network and synthetic data.
They prove the parts this repository owns:

- the restore worker (`internal/recovery`) and its offline SQL check;
- the startup collation step and `check-backup.sh`'s TLS checks from `modules/database-runtime/files`;
- backup and restore through a mutually authenticated TLS repository, and its client and stanza denials.

```bash
docker build -f builds/backup-test.Dockerfile --build-arg DATABASE_SERVICE=json-keys -t backup-test .
docker run --rm --network=none --read-only --tmpfs=/tmp:rw,size=1g,mode=1777 backup-test
```
