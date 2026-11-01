# Costs

This document is about what production pays for, and what bounds each cost.

| Component        | Shape                                                                                                    | Main cost driver                   |
| ---------------- | -------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| Nodes            | 3 × `e2-highmem-4`, up to 4, each with a 30 GiB `pd-balanced` boot disk                                  | VM hours, even when idle           |
| Database volumes | Two instances per database, each with its own `pd-balanced` volume: 10, 30 and 20 GiB                    | Provisioned size                   |
| Backup storage   | One EU multi-region Barman bucket per database, 14 days of base backups and WAL, versioning, soft delete | Stored bytes, including WAL        |
| Platform edges   | One global external Application Load Balancer per platform, with its Certificate Manager certificate     | Forwarding rules and traffic       |
| Internet egress  | Cloud NAT for the nodes, one reserved address, and the egress allowlist's Cloud NGFW FQDN rules          | NAT hours per node                 |
| Images           | Each service's release repository, and the add-ons' pull-through caches                                  | Stored bytes                       |
| Control plane    | The zonal cluster's management fee, which the billing account's free tier covers                         | None                               |
| Everything else  | State, secrets, private DNS (3 zones), Cloud Workflows and their schedules, logs (30 days)               | Small, usage-based                 |
| Grafana Cloud    | The Pro plan, billed apart from Google Cloud                                                             | Usage beyond the plan's allowances |

Backup storage only grows today. Barman expires the base backups and WAL past 14 days, but each
bucket keeps every version it expires, since no lifecycle rule deletes the live lineage's noncurrent
objects. A retired lineage expires whole, 15 days after its objects were written.

The budget is **500 units** of the billing account's currency a month, for the management and
workload projects. Production plans near EUR 360 a month at moderate traffic, which leaves margin.
The budget alerts at 50, 75, 80, 90 and 100%, actual or forecast, and caps nothing. Quotas, the
node pool's maximum and the services' budgets bound most usage, but not storage or traffic.
Foundation sets the workload project's quotas in `europe-west9`: 24 vCPUs, and 1,000 GB of SSD once
Google grants the request, which the nodes' boot disks and the database volumes share.

Grafana Cloud bills apart, and its own alerts warn once a month's usage passes 80% of an allowance,
or costs anything beyond the plan, as [Grafana alerts](runbooks/alerts.md#grafana-alerts) lists.

Recovery drill projects are billed to the same account but sit outside the budget. Delete each one
as soon as its drills end.

Update this page when a node, volume, platform, region or retention setting changes. Prices:
[Compute](https://cloud.google.com/products/compute/pricing),
[disks](https://cloud.google.com/compute/disks-image-pricing),
[GKE](https://cloud.google.com/kubernetes-engine/pricing),
[Cloud Storage](https://cloud.google.com/storage/pricing),
[load balancing](https://cloud.google.com/load-balancing/pricing),
[Cloud NAT](https://cloud.google.com/nat/pricing),
[Cloud NGFW](https://cloud.google.com/firewall/pricing).
