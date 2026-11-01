# Planned downtime

This runbook is about planned downtimes. A planned downtime is an announced period during which some
services stop, so their database can be upgraded safely. A PostgreSQL major upgrade needs one.

## How a downtime unfolds

A downtime lists **components**, one per service whose database will be changed. Each one is
`service-<root>.database`, where `<root>` is the directory of a service root under
`environments/production`, such as `json-keys`. A downtime also has a `start` and an `end`, and goes
through three phases:

| Phase   | When                       | What happens                                                                                                                                      |
| ------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Notice  | Before `start`             | Services work normally. The platform warns users with the dates.                                                                                  |
| Started | From `start` until cleared | Listed services answer `503` / `UNAVAILABLE`, except their liveness ping. JSON Keys skips key rotation. The platform locks the affected features. |
| Cleared | When you clear it          | Services restart and work again.                                                                                                                  |

`end` is only what users were told. A downtime lasts until you clear it, even past its `end`.

There is at most one downtime at a time. It lives in the `DOWNTIME` repository variable as
`{"components": [...], "start": "...", "end": "..."}`, and only `downtime.yaml` writes it. These
read it:

- **the services.** A deploy of the cluster root gives each listed service's workloads and Jobs
  `DOWNTIME_START`, and they stop on their own at that time. No deploy runs at `start`;
- **the platform.** It reads the whole downtime from
  `https://raw.githubusercontent.com/a-novel/infra/downtime/downtime.json`, which holds `null` when
  none is planned. The `downtime` branch holds only that file, replaced on every run;
- **deploys, plans and drift checks.** A PostgreSQL major upgrade merges only while a downtime
  listing that service has started, and the deploy applies it only then. GKE holds every cluster
  upgrade from `start` to `end`.

Users also read the downtime in the public `a-novel-planned-downtime` Discord channel. Each
`downtime.yaml` run hands the `downtime-announcements` Cloud Workflow, in the management project,
every post the downtime still needs:

- the change itself, at once: scheduled, rescheduled, extended, ended or cancelled;
- reminders 1 week, 1 day, 6 hours and 30 minutes before `start`, and one more at `start`.

The workflow sleeps until each post, so they land on time. It reads the webhook from
`production-downtime-discord-webhook` only when it posts, and a new run replaces the pending one.

## Schedule or change a downtime

This stops every service a day from now, for about an hour:

```bash
COMPONENTS='*'
START=1d
END=1h
gh workflow run downtime.yaml --repo a-novel/infra -f operation=schedule \
  -f components="$COMPONENTS" -f start="$START" -f end="$END"
```

| Input        | Takes                                                                                    | Example                                                      |
| ------------ | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `components` | Comma-separated components, or `*` for every service. Empty keeps the current ones.      | `service-json-keys.database,service-authentication.database` |
| `start`      | An RFC 3339 time in UTC, or a delay from now. Empty keeps the current one.               | `2026-10-12T06:00:00Z`                                       |
| `end`        | An RFC 3339 time in UTC, or a length from the start. Always required, and after `start`. | `2026-10-12T07:00:00Z`                                       |

- Only repository admins can run it.
- Durations count days, hours and minutes, such as `30m`, `2h` or `1d12h`.
- Announce a downtime well before its start. Users see it within minutes.
- **List the services that depend on the one you stop.** Authentication signs its tokens through JSON
  Keys, so a JSON Keys downtime should list Authentication too.
- Requests already running at `start` finish normally. Leave a margin before the upgrade.
- Running it again replaces the downtime. A new `end` only changes what users see. A new `start` or
  new components also change when the services stop. A new downtime needs both components and a
  `start`.
- **A started downtime keeps its `start`.** Once it has passed, the run fails unless `start` is
  empty. To extend a downtime, leave `start` empty and pass a later `end`, such as `3h` for three
  hours after the start.

The workflow checks the components and dates, publishes the document and writes `DOWNTIME`. When
the run ends, `deploy.yaml` runs a full deploy, which passes `DOWNTIME_START` to the listed services.
A run that fails before writing `DOWNTIME` deploys nothing. A failure in the announcements alone
still deploys. Every later deploy applies the current `DOWNTIME` too, so a merge landing meanwhile
cannot lose it.

**Check that a deploy succeeded after the change, before `start`.** If none did, the services keep
serving at `start`, until a deploy run by hand gives them `DOWNTIME_START`.

```bash
gh run list --repo a-novel/infra --workflow deploy.yaml --limit 3
```

## While it runs

Merge the upgrades the downtime was planned for, as
[PostgreSQL major upgrades](database.md#postgresql-major-upgrades) describes.

The smoke and health checks skip while the downtime runs, since the listed services refuse work. So
does a check that began just before `start` and failed after it. Check the databases directly
instead ([Inspect a database](database.md#inspect-a-database)).

## Clear the downtime

Clear it once the work is done and verified:

```bash
gh workflow run downtime.yaml --repo a-novel/infra -f operation=clear
```

The workflow deletes `DOWNTIME` and publishes `null`. Then `deploy.yaml` runs a full deploy, which
restarts the services without `DOWNTIME_START`, and runs again each smoke check whose service the
downtime listed.

**Check that a deploy succeeded after the clear.** Until one does, the services keep answering 503.
If none is due, run one by hand:

```bash
gh workflow run deploy.yaml --repo a-novel/infra
```

A forgotten downtime keeps its services down. The
[three-hourly check](alerts.md#planned-downtime-past-its-end) fails once its `end` has passed.
