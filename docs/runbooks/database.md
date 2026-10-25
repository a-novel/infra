# Database hosts

This runbook is about the PostgreSQL hosts. Each service has a database host, and JSON Keys and
Authentication also have a backup repository VM:

- the **database host** is the only member of the instance group `agora-database-<service>`. It runs
  PostgreSQL from the service's `database` image, on a separate data disk `agora-data-<service>`
  that outlives the VM;
- the **backup repository VM** is `agora-pgbackrest-<service>`. The database host sends it WAL and
  backups over mutual TLS, and it stores them in the service's backup bucket.

`<service>` is `json-keys`, `authentication` or `genai`. Their SQL role and database are
`agora_json_keys`, `agora_authentication` and `agora_genai`.
[Architecture](../architecture.md#databases-and-backups) lists their sizes, addresses and schedules.

## Inspect and connect

Humans have read access plus SSH through Identity-Aware Proxy. No host has a public address.

```bash
SERVICE=json-keys
HOST="$(gcloud compute instance-groups managed list-instances "agora-database-$SERVICE" \
  --zone=europe-west1-d --project=a-novel-production-prod --format='value(instance.basename())')"
gcloud compute ssh "$HOST" --zone=europe-west1-d --project=a-novel-production-prod --tunnel-through-iap
```

`gcloud` creates and registers an OS Login key on first use.

A replaced host can present new SSH host keys, and `gcloud` then refuses to connect with "REMOTE
HOST IDENTIFICATION HAS CHANGED". Compare the fingerprint it prints with the key the instance
publishes, and drop the stale entry only when they match:

```bash
gcloud compute instances get-guest-attributes "$HOST" --zone=europe-west1-d \
  --project=a-novel-production-prod --query-path=hostkeys/ssh-ed25519 --format='value(value)' |
  sed 's/^/ssh-ed25519 /' | ssh-keygen -lf -
ID="$(gcloud compute instances describe "$HOST" --zone=europe-west1-d --project=a-novel-production-prod \
  --format='value(id)')"
ssh-keygen -R "compute.$ID" -f ~/.ssh/google_compute_known_hosts
```

Run these on the host. A host without native backups has no `agora-database.service`, and its
startup script runs as `google-startup-scripts.service` instead. The container is
`agora-postgres-<service>` either way.

```bash
SERVICE=json-keys
sudo systemctl status agora-database.service
sudo journalctl -u google-startup-scripts.service --since=-1h
sudo docker ps
df -h /mnt/disks/agora-data
sudo journalctl -u agora-database.service --since=-1h
DB="agora_${SERVICE//-/_}"
sudo docker exec -it --user postgres "agora-postgres-$SERVICE" psql -U "$DB" -d "$DB"
```

The repository VM works the same way. SSH to `agora-pgbackrest-$SERVICE`, whose unit is
`agora-backup-repository.service`.

Never read files under `/run/agora*`, print a container's full configuration, or request a metadata
token. They hold credentials.

## Back up now and verify

Only the hosts in foundation's `native_backups`, JSON Keys and Authentication today, run the
`agora-backup-*` units. Their timers take a full backup on Sundays and a differential backup the
other days, and run a check every hour. GenAI's host has none until
[a-novel/infra#785](https://github.com/a-novel/infra/issues/785) adds its backups, so its only copy
before a host change is the [pre-rollout snapshot](#pre-rollout-snapshots).

To take a backup by hand, for example before a database host change, run on the database host:

```bash
sudo systemctl start --wait agora-backup-check.service
sudo systemctl start --wait agora-backup-full.service
sudo systemctl start --wait agora-backup-verify.service
sudo journalctl -u agora-backup-full.service -u agora-backup-verify.service --since=-2h
```

Keep `--wait`. These units are `Type=exec`, so a plain `start` returns as soon as the container
launches. All three would then run at once, and verify would read the repository before the new
backup exists.

A full backup ends with `backup command end: completed successfully`. The verify report must say
`status: ok`. Read it, since verify can exit 0 even when it reports an error.

## Change a database host

A **database host change** is any change that restarts the database host once applied:

- a new database image digest, which a service release brings;
- a startup, OS or TLS setting, from `native_backups` or `database_*` in foundation's
  `terraform.tfvars`;
- the application role's password version, `database_releases.<service>.app_password_version`;
- the machine type, container size or connection limit (see [capacity](#capacity)).

The database is unavailable while its host restarts, so these changes happen during a
[planned downtime](downtime.md), when the service's users are warned and its services stop. The pull
request's plan enforces it. The plan fails until the pull request carries the `allow-downtime` label
and a planned downtime listing that service has started.

### How the rollout works

Merging a database host change only updates the instance template and the group's configuration,
so the host restarts nothing on apply. Every deploy then ends with a `rollout` job, one per service,
which compares each host with its applied configuration:

```text
deploy:  roots applied ──► rollout (per service) ──► database host exists? ─ no ─► nothing to do
                                                       ▼
                                                     database host differs?
                                                       │ no  ─► nothing to do
                                                       │ yes ─► downtime started? ─ no ─► "rollout pending"
                                                       │                          └ yes ─► service took it? ─ no ─► fail
                                                       │                                                   └ yes ─► snapshot the data disk
                                                       │                                                            restart or replace the host
                                                       │                                                            wait for PostgreSQL
                                                       ▼
                                   backup repository VM differs, or its database host rolled? ─ yes ─► restart it
```

- Before restarting a database host, the job checks that each Cloud Run service writing to the
  database took the downtime. That service's latest revision must be ready and carry the downtime's
  start. Otherwise the job fails, and a deploy run by hand, which gives the service its
  `DOWNTIME_START`, rolls the host.
- The job reads the hosts, not the changes in that deploy. A change applied by a cancelled,
  replaced or force-merged deploy still rolls at the next deploy that runs during the downtime.
- The host keeps its data disk and IP. A template change replaces the VM, and any other change
  restarts it. The database is down for one to two minutes.
- The job then waits up to 10 minutes for PostgreSQL itself. Each boot's startup publishes
  `<state>:<revision>:<boot id>` in the guest attribute `agora/database-release`. The rollout
  succeeds once the new boot reports `healthy`, or `idle` for a host without a release, and fails
  otherwise. A running VM alone proves nothing, since its startup can fail closed and leave
  PostgreSQL stopped.
- The snapshot keeps the data as it stood before the restart, as
  [Pre-rollout snapshots](#pre-rollout-snapshots) describes.
- A **backup repository VM** restarts whenever its `config` label differs from `running-config`, the
  label the rollout sets after each restart. It needs no planned downtime. It also restarts right
  after each restart of its database host, so both run the same pgBackRest version.

### Steps

1. **Schedule a planned downtime** for the service, as
   [Schedule a downtime](downtime.md#schedule-or-change-a-downtime) describes. List the services
   that depend on it too.
2. **Take a full backup and verify it** ([above](#back-up-now-and-verify)) before the downtime
   starts. A service outside `native_backups`, GenAI today, has no backups: its only copy is the
   [snapshot](#pre-rollout-snapshots) the rollout takes before the restart.
3. **Once the downtime has started, add the `allow-downtime` label** to the pull request. Its checks
   re-run and pass.

   ```bash
   PR="<pull request number>"
   gh pr edit "$PR" --repo a-novel/infra --add-label allow-downtime
   ```

   A label added before the downtime started re-ran the checks too early. Re-run the failed plan
   checks once it has started:

   ```bash
   BRANCH="$(gh pr view "$PR" --repo a-novel/infra --json headRefName --jq .headRefName)"
   RUN="$(gh run list --repo a-novel/infra --workflow main.yaml --branch "$BRANCH" --limit 1 \
     --json databaseId --jq '.[0].databaseId')"
   gh run rerun "$RUN" --repo a-novel/infra --failed
   ```

   A push removes the label, because the label approved the plans of an earlier commit. Review the
   new plans and add it again.

4. **Approve and merge.** A maintainer or admin reviews and approves the pull request. An admin who
   opened it may record the approval themselves instead:

   ```bash
   gh workflow run approve-pr.yaml --repo a-novel/infra -f pull_request="$PR"
   ```

   Once the approval shows on the pull request, merge it:

   ```bash
   gh pr merge "$PR" --repo a-novel/infra
   ```

   The deploy applies the change, including a release's migrations, then rolls the host. Its summary
   names the snapshot. A release's smoke job skips its check during the downtime, since the service
   refuses work.

5. **Check the database.** The deploy's health check is skipped while the downtime runs, for the
   same reason. [Connect to the host](#inspect-and-connect) and check `agora-database.service` and
   its log instead.
6. **Clear the downtime**, as [Clear the downtime](downtime.md#clear-the-downtime) describes. Its
   deploy restarts the services, runs the smoke checks the downtime skipped, and checks health
   again.

A database host change merged before its downtime started, by a force-merge for example, still
applies, and every deploy reports "rollout pending". Nothing starts a deploy when a downtime begins,
so once it has started, run a deploy by hand to roll the host:

```bash
gh workflow run deploy.yaml --repo a-novel/infra
```

### Roll a host by hand

`roll-database.yaml` restarts a service's database host and backup repository VM now, whatever the
downtime, then checks health. It takes the same snapshot first. Only admins can run it. Use it when
a host must restart outside a downtime, for example to recover one stuck in a bad state:

```bash
SERVICE=json-keys
gh workflow run roll-database.yaml --repo a-novel/infra -f service="$SERVICE"
```

The database is down for one to two minutes, and users are not warned.

## Fix a bad host change

Database hosts only move forward. A faulty host change is fixed by a new pull request, merged
during the downtime like any host change, as [steps](#steps) 3 and 4 describe.

The new pull request can revert the faulty one. The commit-messages ruleset refuses GitHub's own
`Revert "…"` subject, so revert with git:

```bash
SHA="<squash commit of the faulty pull request>"
BRANCH="<branch name for the revert>"
git fetch origin
git switch -c "$BRANCH" origin/master
git revert --no-commit "$SHA"
git commit -m "revert: $(git log -1 --format=%s "$SHA")" -m "This reverts commit $SHA."
git push -u origin "$BRANCH"
gh pr create --repo a-novel/infra --fill
```

Data damaged by the change goes back through [recovery](recovery.md), as a one-off change planned
on its own.

## Pre-rollout snapshots

Before restarting a database host, the rollout snapshots its data disk as
`agora-data-<service>-<UTC time>`, labelled `role=pre-rollout`. The deploy summary names it, and
this lists them:

```bash
SERVICE=json-keys
gcloud compute snapshots list --project=a-novel-production-prod --format='table(name,creationTimestamp)' \
  --filter="labels.role=pre-rollout AND labels.component=$SERVICE"
```

A snapshot stays until a later rollout of that service finds it older than 14 days. It is recovery
data: the disk as it stood before the restart. The data and WAL share that disk, so PostgreSQL
reads a snapshot as after a power loss.

## Capacity

Each host's machine type, container CPU and memory, data disk size and connection limit are its
entry in foundation's `database_capacity`, in `terraform.tfvars`. A `check` block keeps 1 GiB of
memory and 0.5 vCPU for the host itself. Changing any of them is a
[database host change](#change-a-database-host).

Disks can grow but never shrink. A machine-type change replaces the VM and keeps the disk.

## PostgreSQL major upgrades

A new PostgreSQL major version (`PG_MAJOR`) cannot reuse the data directory. It needs a
dump-and-restore plan of its own.
