# Runbooks

These runbooks cover the operations that still need a human. Everything routine runs on its own,
from deploys and release pins to database rollouts and scheduled checks.
[Ops basics](../ops-basics.md) explains the ideas they rely on.

| Situation                                                 | Runbook                         |
| --------------------------------------------------------- | ------------------------------- |
| Release, hotfix, deletion label, failed deploy, freeze    | [Deployments](deployments.md)   |
| Inspect, back up, change or restore a database host       | [Database hosts](database.md)   |
| Schedule or clear a planned downtime                      | [Planned downtime](downtime.md) |
| Move production from Cloud Run to the cluster             | [Cutover](cutover.md)           |
| Add or rotate a secret, SMTP, waitlist, TLS, GitHub token | [Secrets](secrets.md)           |
| Publish or pin `host-credentials` or `native-restore`     | [Host tools](host-tools.md)     |
| An alert or a failed scheduled check                      | [Alerts](alerts.md)             |
| Restore a backup in a disposable project                  | [Recovery](recovery.md)         |
| A state object is wrong or locked                         | [State](state.md)               |
| Rebuild from nothing, or reconfigure GitHub               | [Setup](setup.md)               |

The commands run from a checkout of this repository. Each `gcloud` command names its project, and
its zone or region, with the values in foundation's `terraform.tfvars`. A default left in your
`gcloud` configuration never redirects it.

Never paste secret values, plans or state into GitHub, chat or logs.
