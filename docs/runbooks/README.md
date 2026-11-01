# Runbooks

These runbooks cover the operations that still need a human. Everything routine runs on its own,
from deploys and release pins to database updates and scheduled checks.
[Ops basics](../ops-basics.md) explains the ideas they rely on.

| Situation                                                 | Runbook                         |
| --------------------------------------------------------- | ------------------------------- |
| Release, hotfix, deletion label, failed deploy, freeze    | [Deployments](deployments.md)   |
| Inspect, change or upgrade a database                     | [Databases](database.md)        |
| Schedule or clear a planned downtime                      | [Planned downtime](downtime.md) |
| Add or rotate a secret, SMTP, a GitHub or a Grafana token | [Secrets](secrets.md)           |
| An alert or a failed scheduled check                      | [Alerts](alerts.md)             |
| Restore a backup in a disposable project                  | [Recovery](recovery.md)         |
| A state object is wrong or locked                         | [State](state.md)               |
| Rebuild from nothing, or reconfigure GitHub               | [Setup](setup.md)               |

The commands run from a checkout of this repository. Each `gcloud` command names its project, and
its location when it takes one. A default left in your `gcloud` configuration never redirects it.

Never paste secret values, plans or state into GitHub, chat or logs.
