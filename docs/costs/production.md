# Production cost worksheet

Reviewed against Google Cloud public USD list prices on 2026-08-25. This is a transparent planning
model, not a quote or an invoice forecast. Google bills actual usage, aggregates some free tiers by
billing account, converts non-USD invoices at its applicable rates, and can change prices. Recheck
the linked pages and the [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator)
before the first apply and before any fixed-cost shape change.

## Cost profiles

| Profile          | What exists                                                                                                                                                                                      | Expected USD/month before tax |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------: |
| Foundation only  | Workload project, VPC/firewalls/routes, three private DNS zones, identities, registry, quotas, budget, bounded logs, one on-demand `e2-medium`, and its 20/50 GiB disks                          |               **about 31–40** |
| Launch           | Foundation with its `e2-medium` running two PostgreSQL containers, plus four-hour backups/snapshots, two scale-to-zero services, and short jobs                                                  |                     **35–55** |
| Capacity horizon | One `e2-standard-2`, four PostgreSQL containers, 150 GiB data disk, retained backups, two private gRPC services, three HTTP services, three to five jobs, and one to two scale-to-zero frontends |                    **85–125** |

The foundation-only range is the cost of applying the code while both database components remain
disabled. The VM stays on but idle, and no PostgreSQL container runs. Compute and provisioned disks
are the fixed cost; three DNS zones add approximately USD 0.60/month. The launch row adds active
database images, 14-day logical retention, daily snapshots, five scale-to-zero recovery jobs, four
short application jobs, and two scale-to-zero services. No resource is currently applied, and this
repository still has no protected apply workflow.

## Current unit assumptions

| Unit                                  | List-price assumption used                                                                                                                                    | Worksheet effect                                                                                                                                                                                                          |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cloud DNS private zone                | USD 0.20/zone/month for the first 25 zones                                                                                                                    | Three zones = USD 0.60/month.                                                                                                                                                                                             |
| Cloud DNS regular queries             | USD 0.40 per million for the first billion monthly queries                                                                                                    | Low launch traffic should remain well below USD 1/month.                                                                                                                                                                  |
| Artifact Registry storage             | First 0.5 GiB per billing account free; then about USD 0.10/GiB-month                                                                                         | Immutable images remain inexpensive; dry-run cleanup exposes growth before deletion is enabled.                                                                                                                           |
| Compute Engine `e2-medium`            | Rounded on-demand `europe-west1` estimate of USD 25–30/month for one continuously running VM                                                                  | The one-member database group has target size one and no autoscaler, so this cost continues while the foundation exists.                                                                                                  |
| Balanced Persistent Disk              | About USD 0.10/GiB-month in `europe-west1`                                                                                                                    | 50 GiB is about USD 5/month; 150 GiB is about USD 15/month. Provisioned, not used, capacity is billed.                                                                                                                    |
| Standard Persistent Disk              | Rounded planning allowance of about USD 1/month for the 20 GiB replaceable COS boot disk                                                                      | Each live database VM has one boot disk. Managed replacement deletes the former boot disk after the new VM takes over.                                                                                                    |
| Same-region standard snapshots        | USD 0.000068493/GiB-hour for stored snapshot data                                                                                                             | The globally scoped snapshots store data in `europe-west1` as the inexpensive fast local-recovery layer; billing follows changed snapshot bytes.                                                                          |
| EU multi-region Cloud Storage         | About USD 0.026/GiB-month, plus USD 0.02/GiB for each replicated write and for reads into `europe-west1`                                                      | The logical-backup formula below includes steady retention, every scheduled write, and one monthly aggregate restore read.                                                                                                |
| Cloud Run services                    | JSON Keys uses request-based CPU; Authentication uses instance-based CPU so detached mail can drain. Both set minimum `0`, maximum `3`, and concurrency `20`. | Both scale to zero. Authentication accrues CPU/memory while an instance remains allocated, even between requests; low launch usage should fit the free allowances, but sustained traffic can materially change the range. |
| Cloud Run jobs                        | Instance-based billing while a task runs; Preview ephemeral disk is USD 0.000109589/GiB-hour in `europe-west1`                                                | Backup and restore use the supported 10 GiB minimum only while running. Short execution keeps disk cost negligible; duration remains measured.                                                                            |
| Cloud Scheduler                       | USD 0.10/job/month, with three jobs free per billing account                                                                                                  | Five recovery schedules plus hourly key rotation add about USD 0.30/month when the billing account's free allowance is otherwise unused.                                                                                  |
| Cloud Logging                         | First 50 GiB/project/month free; then USD 0.50/GiB ingested, including 30-day storage                                                                         | Thirty-day retention and the narrow successful-healthcheck exclusion aim to keep launch logging free without hiding failures.                                                                                             |
| Secret Manager                        | Six active versions per billing account free; then USD 0.06/version-location/month; first 10,000 access operations free                                       | Nine initial active versions would add roughly USD 0.18/month before access overage. Metadata-only containers cost nothing.                                                                                               |
| VPC firewall rules                    | No charge                                                                                                                                                     | The custom VPC, routes, Private Google Access, and ordinary firewall rules have no fixed fee; network transfer can still be billed.                                                                                       |
| Budget, quotas, IAM, service accounts | No fixed product charge                                                                                                                                       | They reduce risk but do not cap every source of spend.                                                                                                                                                                    |

Sources: [Cloud DNS pricing](https://cloud.google.com/dns/pricing),
[Artifact Registry pricing](https://cloud.google.com/artifact-registry/pricing),
[disk and snapshot pricing](https://cloud.google.com/compute/disks-image-pricing),
[Cloud Storage pricing](https://cloud.google.com/storage/pricing),
[Cloud Run pricing and examples](https://cloud.google.com/run/pricing),
[Cloud Scheduler pricing](https://cloud.google.com/scheduler/pricing),
[Cloud Logging pricing](https://cloud.google.com/logging/pricing),
[Secret Manager pricing](https://cloud.google.com/secret-manager/pricing), and
[VPC firewall pricing](https://cloud.google.com/firewall/pricing).

## Launch formula

| Component                   | Planning assumption                                                                                                                           | USD/month |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------: |
| Database compute            | One on-demand `e2-medium` running continuously in `europe-west1`                                                                              |     25–30 |
| Persistent storage          | Preserved balanced data disk plus small boot disk                                                                                             |       5–7 |
| Backups and snapshots       | Two small databases, at most 0.5 GiB combined per restore point, plus seven daily same-region snapshots                                       |       1–5 |
| Cloud Run services and jobs | One request-billed and one instance-billed scale-to-zero service, plus short migrations, initialization, rotation, backup, and restore checks |       0–5 |
| Registry and control plane  | DNS, small state/receipt/image storage, secrets, and bounded logs                                                                             |       1–4 |
| **Expected total**          | Low traffic, no warm instance, no paid edge                                                                                                   | **35–55** |

The database compute row is intentionally a rounded calculator assumption because Compute Engine
prices vary by region, sustained-use eligibility, calendar hours, and pricing-model changes. The
database-host change must refresh the exact calculator estimate before apply. The upper bound leaves
room for snapshot churn and early operational logs without pretending those costs are fixed.

The Cloud Run row assumes Authentication has fewer than roughly ten separated active periods per
day and therefore remains within or near the monthly instance-based free allowances. At current
rounded rates, traffic that keeps one 1 vCPU/512 MiB Authentication instance allocated continuously
can add approximately USD 45–55/month before allowances. That is a measured-usage trigger to revise
the worksheet or move post-response mail onto a request-bound or queued application path; it is not
included in the low-traffic launch range.

At four-hour cadence and 14-day lifecycle, logical retention contains at most 84 completed archives
per database. The capacity formula is therefore:

```text
logical retained GiB = 84 × aggregate compressed GiB of one JSON Keys + Authentication backup
```

At six aggregate backup sets per day, the bucket also receives about 180 aggregate writes each
30-day month. One monthly drill reads one aggregate set from the EU multi-region into
`europe-west1`. At current public unit prices, the recurring logical-backup estimate is:

```text
logical USD/month ≈ (84 × 0.026 + 180 × 0.02 + 1 × 0.02) × aggregate compressed GiB
                  ≈ 5.80 × aggregate compressed GiB
```

Incomplete attempts add a small variable overhead until lifecycle deletion. The hourly monitor
measures all retained objects and fails above 250 GiB. That corresponds to an aggregate current set
of about 3 GiB and approximately USD 17.30/month, leaving headroom below the USD 20 design gate for
partial attempts and small manifests.

## Capacity-horizon formula

| Component                   | Planning assumption                                                                                 |  USD/month |
| --------------------------- | --------------------------------------------------------------------------------------------------- | ---------: |
| Database compute            | One on-demand `e2-standard-2`                                                                       |      50–60 |
| Persistent storage          | 150 GiB balanced data disk plus boot disk                                                           |      15–18 |
| Backups and snapshots       | `84 ×` aggregate compressed current backup size, at most 3 GiB combined, plus same-region snapshots |      15–25 |
| Cloud Run services and jobs | Six to seven mixed-billing scale-to-zero services plus short jobs                                   |       0–15 |
| Registry and control plane  | State/receipts, registry, secrets, scheduler, private DNS, and bounded logs                         |        2–7 |
| **Expected total**          | Low traffic, no warm instances                                                                      | **85–125** |

The four PostgreSQL databases are four isolated containers on one host, not four billed database
instances. The topology moves to `e2-standard-2` before database three. A later `e2-standard-4`
vertical step adds roughly USD 50–60/month and requires an updated worksheet and foundation review.

## Explicit exclusions

These usage-dependent or product decisions are not inside the ranges above:

- tax, non-USD currency conversion, domains, and a custom edge;
- internet data transfer and cross-region transfer beyond the scheduled logical-backup writes and
  monthly restore included above;
- LLM/API usage, paid SMTP/email volume, or provider charges;
- warm Cloud Run instances, paid load balancing, WAF, CDN, Cloud NAT, an egress proxy, or a VPC
  connector;
- multi-zone PostgreSQL high availability, PITR/WAL archival, or managed PostgreSQL;
- abnormal log volume, vulnerability scanning, or image storage outside the stated assumptions.

Authentication uses Cloud Run's direct managed public egress for TLS SMTP; JSON Keys has no public
egress path. No fixed-cost NAT, connector, proxy, or load balancer is included because none is
provisioned.

## Controls and update rule

The 60-unit monthly production-infrastructure budget spans the management and workload projects,
uses the billing account currency, and is alert-only. The USD worksheet remains the planning
comparison. Actual brakes are maximum Cloud Run instances, regional
Cloud Run CPU/memory/Direct VPC quotas, the four-CPU Compute Engine quota, immutable image cleanup
review, bounded log retention, backup lifecycle, and validated disk sizes. Quotas can prevent
some scaling but cannot stop every billable API, transfer, storage, or compromised workload.

Update this worksheet in the same pull request when any of these changes:

- a minimum instance becomes nonzero;
- a VM machine type, disk type/capacity, region, zone count, NAT, connector, proxy, load balancer, or
  other fixed-cost resource changes;
- backup frequency/retention or observed compressed size leaves its assumption;
- measured Cloud Run, log, registry, transfer, or secret usage makes a range inaccurate;
- Google changes a material public unit price.

After deployment, replace assumptions with the prior 30-day billing report while retaining the unit
formula and the low/high uncertainty range. Never export a full OpenTofu plan or secret-bearing state
to a third-party cost service.
