# Cutover

This runbook moves production from Cloud Run to the cluster in one planned downtime
(a-novel/infra#1207). The rehearsal wrote it (a-novel/infra#1202): it imported a copy of production
three times, and every check below passed on the last copy.

## What changes

- The cluster's databases are imported from the database hosts while every service is stopped, so
  nothing writes during the dump.
- `studio.storyverse.fr` points at the cluster's Gateway. Studio on Cloud Run keeps only its
  `run.app` URL.
- GenAI's generations move with their rows: the cluster's sweep starts, and Cloud Run's stops. Only
  one stack may check a generation, since both use the same OpenAI account.
- The database hosts keep their data, untouched, until the retirement (a-novel/infra#1208).

## How long it takes

Announce **one hour**. The work takes about 30 minutes, which leaves room for the way back.

| Step                                  | Measured in the rehearsal                                                                   |
| ------------------------------------- | ------------------------------------------------------------------------------------------- |
| Import, from merge to databases ready | 8 min 16 s: the earlier jobs, a 4-minute pause, then about 1 min 15 s for all three imports |
| GenAI hand-over                       | about 3 min, queued behind the import                                                       |
| Clearing the downtime                 | about 3 min, with the health and smoke checks                                               |
| Sign-in, email and OpenAI call        | about 10 min                                                                                |

The pause is fixed. It lets the old databases and the operator's objects for them go before the new
ones start, since they share their names. The old instances wait up to three minutes for their
clients before stopping. With the services stopped, they stop at once, so the pause can shrink once
a cutover-like run measures it.

**Not rehearsed: an import inside a downtime.** The database clients roll in the import's deploy
while their services refuse work. Their probes call the liveness ping, which a downtime leaves
open, so they should still turn ready. Watch the cluster job for them.

## Prepare

A week ahead:

- a-novel/service-genai#486 is released and pinned, so GenAI schedules its purge again after the
  import.
- OpenAI and the SMTP relay admit the cluster's NAT address, `34.163.101.247`.
- Three pull requests are open, reviewed, approved and green, waiting to merge:

| Pull request    | Change                                                                                                                     | Label                     |
| --------------- | -------------------------------------------------------------------------------------------------------------------------- | ------------------------- |
| Import          | Cluster: `backup_server_name = "database-production"`. Bootstrap: add `database-rehearsal-3` to `retired_barman_lineages`. | `allow-resource-deletion` |
| GenAI hand-over | Cluster: GenAI sweep's `SWEEP_TICKER = "true"`. Foundation: `paused = true` on `google_cloud_scheduler_job.genai_sweep`.   | none                      |
| OpenAI call     | Cluster: `genai_provider_check = "cutover-1"`.                                                                             | none                      |

A day ahead, schedule the downtime. It stops JSON Keys, Authentication and GenAI on both stacks,
and Studio locks the features that need them:

```bash
gh workflow run downtime.yaml --repo a-novel/infra -f operation=schedule \
  -f components=service-json-keys.database,service-authentication.database,service-genai.database \
  -f start=2026-12-10T06:00:00Z -f end=2026-12-10T07:00:00Z
```

Use the window's real dates. Then check that a deploy succeeded after it, as
[Planned downtime](downtime.md#schedule-or-change-a-downtime) asks.

## Run the window

1. **At `start`, silence the alerts.** In Grafana, under **Alerting → Silences**, create a silence
   matching `grafana_folder = Production`, until `end` plus 30 minutes. Recreating a database fires
   every service's fault alerts for a few minutes.
2. **Merge the import, then the GenAI hand-over.** The hand-over's deploy queues behind the
   import's. Follow them:

   ```bash
   gh run list --repo a-novel/infra --workflow deploy.yaml --limit 3
   ```

   The import's cluster job deletes the rehearsal's databases, waits four minutes, imports the three
   databases and waits until each serves and archives its WAL.

3. **Point Studio's name at the cluster.** In Squarespace's DNS for `storyverse.fr`, add the record
   `studio`, type `A`, data `136.81.109.226`, with the shortest TTL it allows, so the way back takes
   effect quickly. Check it at the authoritative server:

   ```bash
   dig +short studio.storyverse.fr A @nsa1.squarespacedns.com
   ```

4. **Once both deploys succeeded, clear the downtime.** Its deploy restarts the services and runs
   the health and smoke checks:

   ```bash
   gh workflow run downtime.yaml --repo a-novel/infra -f operation=clear
   ```

5. **Check the platform.**
   - Sign in at `https://studio.storyverse.fr` with an account from production.
   - Request a password reset, and receive the email.
   - Merge the OpenAI call. Its deploy waits on `provider-check-cutover-1`, which fails unless the
     generation succeeds. A check skipped during the downtime never runs again, so merge it only
     after the clear.
   - In Grafana, the services record no fault after the clear.

6. **Expire the silence.**

## The way back

It stays cheap while nobody has written on the cluster, which, with no users yet, covers the whole
window:

1. Delete the `studio` record.
2. Revert the GenAI hand-over, so Cloud Run's sweep runs again and the cluster's stops.
3. Clear the downtime. Cloud Run serves from the hosts, which nothing has written to since `start`.

The cluster keeps its import. A later attempt imports again under a new lineage name.

## After the window

- **Never change `backup_server_name` until the retirement removes the import.** A new lineage
  recreates each database from its host, whose data stopped at the cutover.
- Cloud Run's services keep running on the hosts' data, reachable only by their `run.app` URLs.
  Retire them soon (a-novel/infra#1208).

## When the import fails

- **A database that times out is tainted.** Never let a later deploy replace it under the same
  lineage: Barman refuses to archive into a path its predecessor filled, and the new database never
  turns ready. Fix forward with a new lineage name, which also retires the failed one.
- Operators can't read CloudNativePG's `Cluster` objects. Follow the database pods and their logs
  instead: an `import` Job, then `database-1`, a `join` Job, and `database-2`.
- A replica that can't join logs `tls: unknown certificate authority` when its certificate and its
  primary's client CA differ. Our CA issues both now, so this points at a certificate that hasn't
  reached the namespace.
