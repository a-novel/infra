# Runbooks

These runbooks cover the operations that still need a human. Everything routine runs on its own,
from deploys and release pins to database rollouts and scheduled checks.
[Ops basics](../ops-basics.md) explains the ideas they rely on.

| Situation                                                 | Runbook                         |
| --------------------------------------------------------- | ------------------------------- |
| Release, roll back, deletion label, failed deploy, freeze | [Deployments](deployments.md)   |
| Inspect, back up, change or restore a database host       | [Database hosts](database.md)   |
| Schedule or clear a planned downtime                      | [Planned downtime](downtime.md) |
| Add or rotate a secret, SMTP, waitlist, TLS, GitHub token | [Secrets](secrets.md)           |
| Publish or pin `host-credentials` or `native-restore`     | [Host tools](host-tools.md)     |
| An alert or a failed scheduled check                      | [Alerts](alerts.md)             |
| Restore a backup in a disposable project                  | [Recovery](recovery.md)         |
| A state object is wrong or locked                         | [State](state.md)               |
| Rebuild from nothing, or reconfigure GitHub               | [Setup](setup.md)               |

The commands run from a checkout of this repository, and expect these variables in your shell:

```bash
export MGMT=a-novel-management-prod PROD=a-novel-production-prod ZONE=europe-west1-d
export STATE=gs://a-novel-management-prod-232403541574-tofu-state
export ORG=1031663934757 BILLING=01BDFE-5B21E7-8393CB
```

Never paste secret values, plans or state into GitHub, chat or logs.
