# Planned downtime

A planned downtime stops the services of the components it lists. From its start, they refuse work
and leave their database alone, which makes database host changes safe.

| Phase   | When                       | What happens                                                                                                                         |
| ------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Notice  | Before `start`             | Services work normally. The platform warns users with the dates.                                                                     |
| Started | From `start` until cleared | Listed services answer `503` / `UNAVAILABLE` except their ping. Their jobs do nothing. The platform locks the affected features.     |
| Cleared | When you clear it          | Services restart and work again. `end` is only what users were told: a downtime outlives it until you clear it, even if it overruns. |

There is at most one downtime, held in the `DOWNTIME` repository variable as
`{"components": [...], "start": "...", "end": "..."}`. Only `downtime.yaml` writes it. From it:

- each listed service receives only `DOWNTIME_START`, at the next deploy;
- the platform reads the whole downtime from
  `https://raw.githubusercontent.com/a-novel/infra/downtime/downtime.json`, which holds `null` when
  none is planned. The `downtime` branch holds that one file, replaced on every run.

## Schedule or change a downtime

```bash
gh workflow run downtime.yaml --repo a-novel/infra -f operation=schedule \
  -f components=service-json-keys.database,service-authentication.database \
  -f start=2026-10-12T06:00:00Z -f end=2026-10-12T07:00:00Z
```

- Components are `service-<root>.database`, one per service root.
- Times are RFC 3339 in UTC. Announce a downtime well before its start; users see it within minutes.
- Running it again replaces the downtime. A new `end` only reaches users. A new `start` or new
  components also restart the affected services.
- **Include the services that depend on the one you stop.** Authentication signs tokens through
  JSON Keys, so a JSON Keys downtime should list Authentication too.
- Requests already running at `start` finish normally. Leave a margin before you stop a database.

The workflow validates the downtime, writes it, publishes the document, and runs a full deploy.

## Clear the downtime

```bash
gh workflow run downtime.yaml --repo a-novel/infra -f operation=clear
```

Nothing else ends a downtime: until you clear it, the listed services keep refusing work, even past
`end`. Clear it once the work is done and verified. The drift check fails every three hours once
`end` has passed, as a reminder to clear it or to announce a later end.

## While it runs

- The deploy health check is skipped, since the services refuse work on purpose.
- Check the work itself directly: database host logs and backup status.
- Don't merge new images of a listed service: their migrations need the database.

## Requirements

`downtime.yaml` writes the variable with the `anovelbot-agent` App, which needs **Variables: Read
and write** on this repository. It publishes the document with the workflow token. Only repository
admins can run it.
