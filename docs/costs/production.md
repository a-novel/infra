# Production cost worksheet

Reviewed against Google Cloud public USD list prices on 2026-08-24. This is a transparent planning
model, not a quote or an invoice forecast. Google bills actual usage, aggregates some free tiers by
billing account, converts non-USD invoices at its applicable rates, and can change prices. Recheck
the linked pages and the [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator)
before the first apply and before any fixed-cost shape change.

## Cost profiles

| Profile          | What exists                                                                                                                                                                                      | Expected USD/month before tax |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------: |
| Foundation only  | Workload project, VPC/firewalls/routes, three private DNS zones, identities, empty or small Artifact Registry, quotas, budget, and bounded logs                                                  |                 **about 1–3** |
| Launch           | Foundation plus one on-demand `e2-medium`, preserved disks, two PostgreSQL containers, four-hour backups/snapshots, two scale-to-zero services, and short jobs                                   |                     **35–50** |
| Capacity horizon | One `e2-standard-2`, four PostgreSQL containers, 150 GiB data disk, retained backups, two private gRPC services, three HTTP services, three to five jobs, and one to two scale-to-zero frontends |                    **75–105** |

The foundation-only range allows modest DNS queries and image/log storage; its only unavoidable
fixed product charge is approximately USD 0.60/month for three Cloud DNS zones. The launch and
capacity rows describe later tickets. This foundation change does not create a VM, disk, database,
backup, Cloud Run service, or job.

## Current unit assumptions

| Unit                                  | List-price assumption used                                                                                              | Worksheet effect                                                                                                                                                           |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cloud DNS private zone                | USD 0.20/zone/month for the first 25 zones                                                                              | Three zones = USD 0.60/month.                                                                                                                                              |
| Cloud DNS regular queries             | USD 0.40 per million for the first billion monthly queries                                                              | Low launch traffic should remain well below USD 1/month.                                                                                                                   |
| Artifact Registry storage             | First 0.5 GiB per billing account free; then about USD 0.10/GiB-month                                                   | Immutable images remain inexpensive; dry-run cleanup exposes growth before deletion is enabled.                                                                            |
| Balanced Persistent Disk              | About USD 0.10/GiB-month in `europe-west1`                                                                              | 50 GiB is about USD 5/month; 150 GiB is about USD 15/month. Provisioned, not used, capacity is billed.                                                                     |
| Cloud Run services                    | Request-based, minimum instances `0`, explicit concurrency and maximum instances                                        | Idle service cost is zero; request, CPU, memory, and network usage remain variable. Google's current `europe-west1` example costs USD 13.69/month at ten million requests. |
| Cloud Run jobs                        | Instance-based billing while a task runs, one-minute minimum                                                            | Google's hourly one-minute, 1 vCPU/512 MiB example remains within the free tier; actual migration and backup duration is measured.                                         |
| Cloud Logging                         | First 50 GiB/project/month free; then USD 0.50/GiB ingested, including 30-day storage                                   | Thirty-day retention and the narrow successful-healthcheck exclusion aim to keep launch logging free without hiding failures.                                              |
| Secret Manager                        | Six active versions per billing account free; then USD 0.06/version-location/month; first 10,000 access operations free | Seven initial active versions would add roughly USD 0.06/month before access overage. Metadata-only containers cost nothing.                                               |
| VPC firewall rules                    | No charge                                                                                                               | The custom VPC, routes, Private Google Access, and ordinary firewall rules have no fixed fee; network transfer can still be billed.                                        |
| Budget, quotas, IAM, service accounts | No fixed product charge                                                                                                 | They reduce risk but do not cap every source of spend.                                                                                                                     |

Sources: [Cloud DNS pricing](https://cloud.google.com/dns/pricing),
[Artifact Registry pricing](https://cloud.google.com/artifact-registry/pricing),
[disk and snapshot pricing](https://cloud.google.com/compute/disks-image-pricing),
[Cloud Run pricing and examples](https://cloud.google.com/run/pricing),
[Cloud Logging pricing](https://cloud.google.com/logging/pricing),
[Secret Manager pricing](https://cloud.google.com/secret-manager/pricing), and
[VPC firewall pricing](https://cloud.google.com/firewall/pricing).

## Launch formula

| Component                   | Planning assumption                                                                                                  | USD/month |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------- | --------: |
| Database compute            | One on-demand `e2-medium` running continuously in `europe-west1`                                                     |     25–30 |
| Persistent storage          | Preserved balanced data disk plus small boot disk                                                                    |       5–7 |
| Backups and snapshots       | Two small databases, 14 days of four-hour logical restore points, seven daily snapshots                              |       1–4 |
| Cloud Run services and jobs | Two request-billed scale-to-zero services and short migrations, initialization, rotation, backup, and restore checks |       0–5 |
| Registry and control plane  | DNS, small state/receipt/image storage, secrets, and bounded logs                                                    |       1–4 |
| **Expected total**          | Low traffic, no warm instance, no paid edge                                                                          | **35–50** |

The database compute row is intentionally a rounded calculator assumption because Compute Engine
prices vary by region, sustained-use eligibility, calendar hours, and pricing-model changes. The
database-host change must refresh the exact calculator estimate before apply. The upper bound leaves
room for snapshot churn and early operational logs without pretending those costs are fixed.

## Capacity-horizon formula

| Component                   | Planning assumption                                                                                   |  USD/month |
| --------------------------- | ----------------------------------------------------------------------------------------------------- | ---------: |
| Database compute            | One on-demand `e2-standard-2`                                                                         |      50–60 |
| Persistent storage          | 150 GiB balanced data disk plus boot disk                                                             |      15–18 |
| Backups and snapshots       | 84 logical restore points per database, aggregate compressed data at most 4 GiB, light snapshot churn |       5–10 |
| Cloud Run services and jobs | Six to seven scale-to-zero services plus short jobs                                                   |       0–15 |
| Registry and control plane  | State/receipts, registry, secrets, scheduler, private DNS, and bounded logs                           |        2–7 |
| **Expected total**          | Low traffic, no warm instances                                                                        | **75–105** |

The four PostgreSQL databases are four isolated containers on one host, not four billed database
instances. The topology moves to `e2-standard-2` before database three. A later `e2-standard-4`
vertical step adds roughly USD 50–60/month and requires an updated worksheet and foundation review.

## Explicit exclusions

These usage-dependent or product decisions are not inside the ranges above:

- tax, non-USD currency conversion, domains, and a custom edge;
- internet data transfer and unusually high cross-region transfer;
- LLM/API usage, paid SMTP/email volume, or provider charges;
- warm Cloud Run instances, paid load balancing, WAF, CDN, Cloud NAT, an egress proxy, or a VPC
  connector;
- multi-zone PostgreSQL high availability, PITR/WAL archival, or managed PostgreSQL;
- abnormal log volume, vulnerability scanning, or image storage outside the stated assumptions.

Authentication uses Cloud Run's direct managed public egress for TLS SMTP; JSON Keys has no public
egress path. No fixed-cost NAT, connector, proxy, or load balancer is included because none is
provisioned.

## Controls and update rule

The 60-unit monthly workload budget uses the billing account currency and is alert-only. The USD
worksheet remains the planning comparison. Actual brakes are maximum Cloud Run instances, regional
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
