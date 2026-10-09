# Runbooks

Everything routine is automated: merging deploys, and drift and health checks run on a schedule.
These runbooks cover what still needs a human.

| Situation                                         | Runbook                         |
| ------------------------------------------------- | ------------------------------- |
| Release, roll back, deletion label, failed deploy | [Deployments](deployments.md)   |
| Inspect, SSH, back up or restart a database host  | [Database hosts](database.md)   |
| Schedule or clear a planned downtime              | [Planned downtime](downtime.md) |
| Add or rotate a secret, SMTP, waitlist, TLS       | [Secrets](secrets.md)           |
| An alert or a failed scheduled check              | [Alerts](alerts.md)             |
| Restore a backup in a disposable project          | [Recovery](recovery.md)         |
| A state object is wrong or locked                 | [State](state.md)               |
| Rebuild from nothing, or reconfigure GitHub       | [Setup](setup.md)               |

Each runbook expects these variables in your shell:

```bash
export MGMT=a-novel-management-prod PROD=a-novel-production-prod API=a-novel-public-api-prod
export STATE=gs://a-novel-management-prod-232403541574-tofu-state ZONE=europe-west1-d
```

Never paste secret values, plans or state into GitHub, chat or logs.
