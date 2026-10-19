# foundation

The long-lived production infrastructure every service shares: the trust-zone projects, the
network, each service's database host, and the shared IAM, schedules, quotas and alerts.
[Architecture](../../../docs/architecture.md) describes what runs where.

Database hosts never restart on apply.
[How the rollout works](../../../docs/runbooks/database.md#how-the-rollout-works) explains how a
change reaches them.
