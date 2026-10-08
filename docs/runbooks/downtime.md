# Planned downtime

A planned downtime is one announced window. The services it lists refuse work and leave their
database alone, which makes database host changes safe.

| Phase       | When                       | What happens                                                                                                                             |
| ----------- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Notice      | Before `start`             | Services work normally. The platform warns users with the dates.                                                                         |
| In progress | From `start` until cleared | Listed services answer `503` / `UNAVAILABLE`, except health and status. Their jobs do nothing. The platform locks the affected features. |
| Cleared     | When you clear it          | Services work again. `end` is only what users were told; nothing ends the window but you.                                                |

There is at most one window, held in the `DOWNTIME` repository variable. Only `downtime.yaml`
writes it, and every deploy applies it.

## Schedule or change a window

```bash
gh workflow run downtime.yaml --repo a-novel/infra -f operation=schedule \
  -f services=json-keys,authentication -f start=2026-10-12T06:00:00Z -f end=2026-10-12T07:00:00Z
```

- Times are RFC 3339 in UTC. Announce a window well before its start; users see it right away.
- Running it again replaces the window, which is how you move the dates or add a service.
- **Include the services that depend on the one you stop.** Authentication signs tokens through
  JSON Keys, so a JSON Keys window should list Authentication too.
- Requests already running at `start` finish normally. Leave a margin before you stop a database.

The workflow validates the window, writes it, and runs a full deploy, which gives every service the
new window.

## Clear the window

```bash
gh workflow run downtime.yaml --repo a-novel/infra -f operation=clear
```

Clear it as soon as the work is done: until you do, the listed services keep refusing work. The
drift check fails every three hours once `end` has passed.

## During a window

- The deploy health check is skipped, since the services refuse work on purpose.
- Check the work itself directly: database host logs, backup status, the services' health routes.

## Requirements

`downtime.yaml` writes the variable with the `anovelbot-agent` App, which needs **Variables: Read
and write** on this repository. Only repository admins can run it.
