# foundation

The long-lived production infrastructure that every service shares. It owns the trust-zone
projects, the Shared VPC with its firewall and private DNS, and each service's database host. It
also holds the shared IAM, the invocation tags and schedules that run the services' jobs, the
`agora-production` registry of database images, and the quotas, budget and alerts.

See [architecture](../../../docs/architecture.md). Database hosts never restart on apply; see
[database hosts](../../../docs/runbooks/database.md).
