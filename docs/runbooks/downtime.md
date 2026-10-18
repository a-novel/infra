# Planned downtime

A planned downtime is an announced period during which some services stop on purpose, so their
database can be changed safely. This runbook covers how one is scheduled, what users and services
see, and how it ends.

## How a downtime unfolds

A downtime lists **components**, `service-<root>.database`, one per service whose database will be
changed. `<root>` is the directory of any service root under `environments/production`, such as
`json-keys`. `*` lists them all. It has a `start` and an `end`, and goes through three phases:

| Phase   | When                       | What happens                                                                                                                                      |
| ------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Notice  | Before `start`             | Services work normally. The platform warns users with the dates.                                                                                  |
| Started | From `start` until cleared | Listed services answer `503` / `UNAVAILABLE`, except their liveness ping. JSON Keys skips key rotation. The platform locks the affected features. |
| Cleared | When you clear it          | Services restart and work again.                                                                                                                  |

`end` is only what users were told. A downtime lasts until you clear it, even past its `end`.

There is at most one downtime at a time. It lives in the `DOWNTIME` repository variable as
`{"components": [...], "start": "...", "end": "..."}`, and only `downtime.yaml` writes it. These read
it:

- **the services.** At each deploy, a listed service receives `DOWNTIME_START` and stops on its own
  at that time. No deploy runs at `start`;
- **the platform.** It reads the whole downtime from
  `https://raw.githubusercontent.com/a-novel/infra/downtime/downtime.json`, which holds `null` when
  none is planned. The `downtime` branch holds only that file, replaced on every run.
- **the Discord announcements** in the public `a-novel-planned-downtime` channel. Each
  `downtime.yaml` run hands the `downtime-announcements` Cloud Workflow, in the management project,
  every post the downtime still needs. The first announces the change: scheduled, rescheduled,
  extended, ended or cancelled. Reminders follow 1 week, 1 day, 6 hours and 30 minutes before
  `start`, and one more at `start`. The workflow sleeps until each post, so they land on time. It
  reads the webhook from `production-downtime-discord-webhook` only when it posts, and a new run
  replaces the pending one.

Deploys, plans and drift checks read `DOWNTIME` too. A database host change merges only while a
downtime listing that service has started, and the deploy rolls the host only then.
[Change a database host](database.md#change-a-database-host) walks through it.

## Schedule or change a downtime

This one stops every service in a day, for about an hour:

```bash
gh workflow run downtime.yaml --repo a-novel/infra -f operation=schedule \
  -f 'components=*' -f start=1d -f end=1h
```

This one stops two services at fixed times:

```bash
gh workflow run downtime.yaml --repo a-novel/infra -f operation=schedule \
  -f components=service-json-keys.database,service-authentication.database \
  -f start=2026-10-12T06:00:00Z -f end=2026-10-12T07:00:00Z
```

- Only repository admins can run it.
- `start` is an RFC 3339 time in UTC or a delay from now. `end` is an RFC 3339 time in UTC or a
  length from the start. Durations count days, hours and minutes: `30m`, `2h`, `1d12h`. `end` must
  come after `start`. Announce a downtime well before its start: users see it within minutes.
- **List the services that depend on the one you stop.** Authentication signs its tokens through JSON
  Keys, so a JSON Keys downtime should list Authentication too.
- Requests already running at `start` finish normally. Leave a margin before the database host
  restarts.
- Running it again replaces the downtime. A new `end` only changes what users see. A new `start` or
  new components also change when the services stop. Empty `components` or `start` keep the current
  ones, so a new downtime needs both.
- **A started downtime keeps its `start`.** Once it has passed, the run fails unless `start` is
  empty. To extend a downtime, leave `start` empty and pass a later `end`, such as `-f end=3h` for
  three hours after the start.

The workflow checks the components and dates, publishes the document and writes `DOWNTIME`. When
the run ends, `deploy.yaml` runs a full deploy, which passes `DOWNTIME_START` to the listed services.
A run that fails before writing `DOWNTIME` deploys nothing. A failure in the announcements alone
still deploys. Every later deploy applies the current `DOWNTIME` too, so a merge landing meanwhile
cannot lose it.
**Check that a deploy succeeded after the change, before `start`:** if none did, the services keep
serving at `start`. The rollout then refuses to restart their database hosts, until a deploy run by
hand gives them `DOWNTIME_START`.

## While it runs

- Merge the database host changes the downtime was planned for, with the `allow-downtime` label.
  Their deploy runs a release's migrations, then rolls the hosts. Migrations still run during a
  downtime; the smoke checks wait for the downtime to be cleared.
- The deploy health check is skipped, since the listed services refuse work. So is a health or
  smoke check that began just before `start` and failed after it. Check the database hosts directly
  ([Inspect and connect](database.md#inspect-and-connect)).

## Clear the downtime

```bash
gh workflow run downtime.yaml --repo a-novel/infra -f operation=clear
```

Clear it once the work is done and verified. The workflow deletes `DOWNTIME` and publishes `null`,
then `deploy.yaml` runs a full deploy, which restarts the services without `DOWNTIME_START`. The
health check runs again, and so does each smoke check whose service the downtime listed.
**Check that a deploy succeeded after the clear:** until one does, the services keep answering 503.
If none is due, run one by hand (`gh workflow run deploy.yaml --repo a-novel/infra --ref master`).

A forgotten downtime keeps its services down. The drift workflow fails every three hours once `end`
has passed, as a reminder to clear it or to schedule a later end.

## Requirements

`downtime.yaml` writes the variable with the `anovelbot-agent` App, which needs **Variables: Read
and write** on this repository. Its key is a secret of the `governance` environment. The workflow
token publishes the document.
