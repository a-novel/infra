# Planned downtime

A planned downtime is an announced period during which some services stop on purpose, so their
database can be changed safely. This runbook covers how one is scheduled, what users and services
see, and how it ends.

## How a downtime unfolds

A downtime lists **components**, `service-<root>.database`, one per service whose database will be
changed. `<root>` is the service root's directory under `environments/production`: `json-keys` or
`authentication`. It has a `start` and an `end`, and goes through three phases:

| Phase   | When                       | What happens                                                                                                                                      |
| ------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Notice  | Before `start`             | Services work normally. The platform warns users with the dates.                                                                                  |
| Started | From `start` until cleared | Listed services answer `503` / `UNAVAILABLE`, except their liveness ping. JSON Keys skips key rotation. The platform locks the affected features. |
| Cleared | When you clear it          | Services restart and work again.                                                                                                                  |

`end` is only what users were told. A downtime lasts until you clear it, even past its `end`.

There is at most one downtime at a time. It lives in the `DOWNTIME` repository variable as
`{"components": [...], "start": "...", "end": "..."}`, and only `downtime.yaml` writes it. Three things
read it:

- **the services.** At each deploy, a listed service receives `DOWNTIME_START` and stops on its own
  at that time. No deploy runs at `start`;
- **the platform.** It reads the whole downtime from
  `https://raw.githubusercontent.com/a-novel/infra/downtime/downtime.json`, which holds `null` when
  none is planned. The `downtime` branch holds only that file, replaced on every run.
- **the Discord announcements.** `downtime.yaml` posts each change to the public
  `a-novel-planned-downtime` channel: scheduled, rescheduled, extended (same start, later end), ended
  or cancelled. `downtime-reminders.yaml` posts 1 week, 1 day, 6 hours and 30 minutes before `start`,
  then at `start`. It runs every 10 minutes, so a reminder comes up to 10 minutes late, more when
  GitHub delays its scheduled runs.

Deploys, plans and drift checks read `DOWNTIME` too. A database host change merges only while a
downtime listing that service has started, and the deploy rolls the host only then: see
[Change a database host](database.md#change-a-database-host).

## Schedule or change a downtime

```bash
gh workflow run downtime.yaml --repo a-novel/infra -f operation=schedule \
  -f components=service-json-keys.database,service-authentication.database \
  -f start=2026-10-12T06:00:00Z -f end=2026-10-12T07:00:00Z
```

- Only repository admins can run it.
- Times are RFC 3339 in UTC, and `end` must come after `start`. Announce a downtime well before its
  start: users see it within minutes.
- **List the services that depend on the one you stop.** Authentication signs its tokens through JSON
  Keys, so a JSON Keys downtime should list Authentication too.
- Requests already running at `start` finish normally. Leave a margin before the database host
  restarts.
- Running it again replaces the downtime. A new `end` only changes what users see. A new `start` or
  new components also change when the services stop.

The workflow checks the components and dates, writes `DOWNTIME`, publishes the document, then runs a
full deploy, which passes `DOWNTIME_START` to the listed services. **Check that this deploy succeeded
before `start`:** if it failed, the services keep serving at `start`. The rollout then refuses to
restart their database hosts, until a deploy run by hand gives them `DOWNTIME_START`.

## While it runs

- Merge the database host changes the downtime was planned for, with the `allow-downtime` label.
  Their deploy runs a release's migrations, then rolls the hosts. Migrations still run during a
  downtime; the JSON Keys smoke check waits for the downtime to be cleared.
- The deploy health check is skipped, since the listed services refuse work. Check the database hosts
  directly ([Inspect and connect](database.md#inspect-and-connect)).

## Clear the downtime

```bash
gh workflow run downtime.yaml --repo a-novel/infra -f operation=clear
```

Clear it once the work is done and verified. The workflow deletes `DOWNTIME`, publishes `null`, and
runs a full deploy, which restarts the services without `DOWNTIME_START`. The health check runs
again, and so does the JSON Keys smoke check when the downtime listed JSON Keys.

A forgotten downtime keeps its services down. The drift workflow fails every three hours once `end`
has passed, as a reminder to clear it or to schedule a later end.

## Requirements

`downtime.yaml` writes the variable with the `anovelbot-agent` App, which needs **Variables: Read
and write** on this repository, and publishes the document with the workflow token.
