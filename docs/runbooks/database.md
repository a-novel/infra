# Database hosts

This runbook covers the PostgreSQL hosts: how to look at them, back them up, change them, and undo
a change. Each service has its own pair of VMs:

- the **database host**, the only member of the instance group `agora-database-<service>`. It runs
  PostgreSQL from the service's `database` image, on a separate data disk `agora-data-<service>`
  that outlives the VM;
- the **backup repository VM** `agora-pgbackrest-<service>`. The database host sends it WAL and
  backups over mutual TLS, and it stores them in the service's backup bucket.

`<service>` is `json-keys` or `authentication`. Their SQL role and database are `agora_json_keys`
and `agora_authentication`. [Architecture](../architecture.md#databases-and-backups) lists their
sizes, addresses and schedules.

## Inspect and connect

Humans have read access plus SSH through Identity-Aware Proxy. No host has a public address.

```bash
SERVICE=json-keys
HOST="$(gcloud compute instance-groups managed list-instances "agora-database-$SERVICE" \
  --zone="$ZONE" --project="$PROD" --format='value(instance.basename())')"
gcloud compute ssh "$HOST" --zone="$ZONE" --project="$PROD" --tunnel-through-iap
```

`gcloud` creates and registers an OS Login key on first use.

A host that was replaced can present new SSH host keys, and `gcloud` then refuses to connect with
"REMOTE HOST IDENTIFICATION HAS CHANGED". Compare the fingerprint it prints with the key the
instance publishes, and drop the stale entry only when they match:

```bash
gcloud compute instances get-guest-attributes "$HOST" --zone="$ZONE" --project="$PROD" \
  --query-path=hostkeys/ssh-ed25519 --format='value(value)' | sed 's/^/ssh-ed25519 /' | ssh-keygen -lf -
ID="$(gcloud compute instances describe "$HOST" --zone="$ZONE" --project="$PROD" --format='value(id)')"
ssh-keygen -R "compute.$ID" -f ~/.ssh/google_compute_known_hosts
```

On the host:

```bash
sudo systemctl status agora-database.service
sudo docker ps
df -h /mnt/disks/agora-data
sudo journalctl -u agora-database.service --since=-1h
DB="agora_${SERVICE//-/_}"
sudo docker exec -it --user postgres "agora-postgres-$SERVICE" psql -U "$DB" -d "$DB"
```

The repository VM works the same way: SSH to `agora-pgbackrest-$SERVICE`, whose unit is
`agora-backup-repository.service`.

Never read files under `/run/agora*`, print a container's full configuration, or request a metadata
token: they hold credentials.

## Back up now and verify

Timers take a full backup on Sundays, a differential backup the other days, and run a check every
hour. To take a backup by hand, for example before a database host change, run on the database host:

```bash
sudo systemctl start --wait agora-backup-check.service
sudo systemctl start --wait agora-backup-full.service
sudo systemctl start --wait agora-backup-verify.service
sudo journalctl -u agora-backup-full.service -u agora-backup-verify.service --since=-2h
```

Keep `--wait`. These units are `Type=exec`, so a plain `start` returns as soon as the container
launches: all three would run at once, and verify would read the repository before the new backup
exists.

A full backup ends with `backup command end: completed successfully`. The verify report must say
`status: ok`. Read it: verify can exit 0 even when it reports an error.

## Change a database host

A **database host change** is any change that restarts the database host once applied:

- a new database image digest, which a service release brings;
- a startup, OS or TLS setting: `native_backups` or `database_*` in foundation's
  `terraform.tfvars`;
- a database password version: `database_releases.<service>.password_version`;
- the machine type, container size or connection limit (see [capacity](#capacity)).

The database is unavailable while its host restarts, so these changes happen during a
[planned downtime](downtime.md), when the service's users are warned and its services stop on
purpose. The pull request plan enforces it: it fails until the pull request carries the
`allow-downtime` label and a planned downtime listing that service has started.

### How the rollout works

Merging a database host change only updates the instance template and the group's configuration.
The host restarts nothing on apply. Every deploy then ends with a `rollout` job, one per service,
which compares each host with its applied configuration:

```text
deploy:  roots applied ──► rollout (per service) ──► database host differs?
                                                       │ no  ─► nothing to do
                                                       │ yes ─► downtime started? ─ no ─► "rollout pending"
                                                       │                          └ yes ─► snapshot the data disk
                                                       │                                   restart or replace the host
                                                       ▼
                                   backup repository VM differs? ─ yes ─► restart it, after the database host
```

- The job reads the hosts, not the changes in that deploy. A change applied by a cancelled,
  replaced or force-merged deploy still rolls at the next deploy that runs during the downtime.
- The host keeps its data disk and IP. A template change replaces the VM; any other change restarts
  it. The database is down for one to two minutes.
- The snapshot is the way back: see [Undo a rollout](#undo-a-rollout).
- A **backup repository VM** restarts whenever its `config` label differs from `running-config`, the
  label the rollout sets after each restart. It needs no planned downtime, and it restarts right after
  its database host when both changed, so both run the same pgBackRest version.

### Steps

1. **Schedule a planned downtime** for the service: see [Schedule a downtime](downtime.md#schedule-or-change-a-downtime).
   List the services that depend on it too.
2. **Take a full backup and verify it** ([above](#back-up-now-and-verify)) before the downtime
   starts.
3. **Once the downtime has started, add the `allow-downtime` label** to the pull request. Its checks
   re-run and pass. A label added earlier does not re-run them when the downtime starts: re-run the
   failed plan checks by hand. A push removes the label, because it approved the plans of the commit
   it was added on: review the new plans and add it again.
4. **Approve and merge.** The deploy applies the change, including a release's migrations, then
   rolls the host. Its summary names the snapshot.

   A JSON Keys release fails here for now: its smoke job calls a status RPC that the service refuses
   during a downtime, so the JSON Keys apply fails and the rollout is skipped. The foundation apply
   before it has already updated the host's configuration: [roll the host by hand](#roll-a-host-by-hand),
   check it, then clear the downtime. The clear's deploy runs the smoke job again, against the
   restarted service, and finishes the release.

5. **Check the database.** The deploy's health check is skipped while the downtime runs, since the
   services refuse work on purpose. [Connect to the host](#inspect-and-connect) and check
   `agora-database.service` and its log instead.
6. **Clear the downtime** ([Clear the downtime](downtime.md#clear-the-downtime)). Its deploy
   restarts the services, and the health check runs again.

A database host change merged before its downtime started, by a force-merge for example, still
applies, and every deploy reports "rollout pending". Once the downtime has started, run a deploy by
hand to roll it: `gh workflow run deploy.yaml --repo a-novel/infra`. Nothing else starts a deploy
when a downtime begins.

### Roll a host by hand

`roll-database.yaml` restarts a service's database host and backup repository VM at once, whatever
the downtime, then checks health. It takes the same snapshot first. Use it when a host must restart
outside a downtime, for example to recover one stuck in a bad state:

```bash
gh workflow run roll-database.yaml --repo a-novel/infra -f service=json-keys
```

The database is down for one to two minutes, and users are not warned.

## Undo a rollout

Before restarting a database host, the rollout snapshots its data disk as
`agora-data-<service>-<UTC time>`, labelled `role=pre-rollout`. The deploy summary names it. A
snapshot stays until a later rollout of that service finds it older than 14 days. The data and WAL share that disk, so PostgreSQL recovers the snapshot as after a
power loss.

1. **Revert the pull request** and merge the revert during the downtime. The deploy rolls the host
   back onto the previous configuration. That is enough when the data is intact, for example when
   the new image failed to start.
2. **If the data is damaged, put back the disk** from the snapshot that the faulty rollout took. The
   revert's own rollout has just snapshotted the damaged disk, so that copy stays available for
   inspection.

   ```bash
   SERVICE=json-keys SNAPSHOT=agora-data-json-keys-<UTC time of the faulty rollout>
   gh workflow disable deploy.yaml --repo a-novel/infra
   where=(--zone="$ZONE" --project="$PROD")
   group="agora-database-$SERVICE" disk="agora-data-$SERVICE"
   instance="$(gcloud compute instance-groups managed list-instances "$group" "${where[@]}" --format='value(name)')"
   gcloud compute disks describe "$disk" "${where[@]}" --format=json >"$disk.json"
   gcloud compute instance-groups managed stop-instances "$group" --instances="$instance" "${where[@]}"
   gcloud compute instances detach-disk "$instance" --device-name=agora-data "${where[@]}"
   gcloud compute disks delete "$disk" --quiet "${where[@]}"
   gcloud compute disks create "$disk" --source-snapshot="$SNAPSHOT" --type=pd-balanced \
     --size="$(jq -r .sizeGb "$disk.json")GB" --description="$(jq -r .description "$disk.json")" \
     --labels="$(jq -r '.labels | to_entries | map("\(.key)=\(.value)") | join(",")' "$disk.json")" "${where[@]}"
   gcloud compute instances attach-disk "$instance" --disk="$disk" --device-name=agora-data "${where[@]}"
   gcloud compute instance-groups managed start-instances "$group" --instances="$instance" "${where[@]}"
   gh workflow enable deploy.yaml --repo a-novel/infra
   ```

   - **Deploys stay off between the stop and the start.** Stopping lowers the group's target size,
     and a foundation apply would restore it by creating a second host. Renovate's merges and
     `downtime.yaml` both start deploys, so the block disables the workflow first.
   - The detach waits for the host to stop, about two minutes.
   - The new disk keeps the old name, so the group and the host find it, and the host keeps its name
     and IP. OpenTofu ignores the disk's source snapshot, so its state needs no change. This
     procedure was rehearsed on a throwaway group, including a later rollout that reattached the
     restored disk.

3. **Wait until the database answers, then clear the downtime.** The template records the data
   disk's ID, so every foundation plan now changes the host's template, and needs a planned downtime,
   until one merges. Run a deploy by hand before you clear the downtime to apply it right away.

## Capacity

The machine type, container CPU and memory, data disk size and connection limit are the
`database_*` variables of foundation's `variables.tf`, whose defaults are in use. Override them in
foundation's `terraform.tfvars`. A `check` block keeps 1 GiB of memory and 0.5 vCPU for the host
itself. Changing any of them is a
[database host change](#change-a-database-host).

Disks can grow but never shrink. A machine-type change replaces the VM, not the disk.

## PostgreSQL major upgrades

A new PostgreSQL major version (`PG_MAJOR`) cannot reuse the data directory. It needs a
dump-and-restore plan of its own.
