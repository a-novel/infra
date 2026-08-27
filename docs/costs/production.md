# Production cost worksheet

Reviewed against Google Cloud and hosted Plunk public USD list prices on 2026-08-27. This is a
transparent planning model, not a quote or an invoice forecast. Google bills actual usage,
aggregates some free tiers by
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
repository deploys nothing until a protected workflow is manually dispatched from `master`.

## Current unit assumptions

| Unit                                  | List-price assumption used                                                                                                                                    | Worksheet effect                                                                                                                                                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cloud DNS private zone                | USD 0.20/zone/month for the first 25 zones                                                                                                                    | Three zones = USD 0.60/month.                                                                                                                                                                                        |
| Cloud DNS regular queries             | USD 0.40 per million for the first billion monthly queries                                                                                                    | Low launch traffic should remain well below USD 1/month.                                                                                                                                                             |
| Artifact Registry storage             | First 0.5 GiB per billing account free; then about USD 0.10/GiB-month                                                                                         | Immutable images remain inexpensive; dry-run cleanup exposes growth before deletion is enabled.                                                                                                                      |
| Compute Engine `e2-medium`            | Rounded on-demand `europe-west1` estimate of USD 25–30/month for one continuously running VM                                                                  | The one-member database group has target size one and no autoscaler, so this cost continues while the foundation exists.                                                                                             |
| Balanced Persistent Disk              | About USD 0.10/GiB-month in `europe-west1`                                                                                                                    | 50 GiB is about USD 5/month; 150 GiB is about USD 15/month. Provisioned, not used, capacity is billed.                                                                                                               |
| Standard Persistent Disk              | Rounded planning allowance of about USD 1/month for the 20 GiB replaceable COS boot disk                                                                      | Each live database VM has one boot disk. Managed replacement deletes the former boot disk after the new VM takes over.                                                                                               |
| Same-region standard snapshots        | USD 0.000068493/GiB-hour for stored snapshot data                                                                                                             | The globally scoped snapshots store data in `europe-west1` as the inexpensive fast local-recovery layer; billing follows changed snapshot bytes.                                                                     |
| EU multi-region Cloud Storage         | About USD 0.026/GiB-month, plus USD 0.02/GiB for each replicated write and for reads into `europe-west1`                                                      | The logical-backup formula below includes steady retention, scheduled writes, the monthly drill, and one backup/restore verification per release.                                                                    |
| Cloud Run services                    | JSON Keys uses request-based CPU; Authentication uses instance-based CPU so detached mail can drain. Both set minimum `0`, maximum `3`, and concurrency `20`. | Both scale to zero. Authentication accrues CPU/memory while an instance remains allocated, even between requests. The three-hour synthetic check creates eight bounded wakes/day instead of continuously warming it. |
| Cloud Run jobs                        | Instance-based billing while a task runs; Preview ephemeral disk is USD 0.000109589/GiB-hour in `europe-west1`                                                | Backup and restore use the supported 10 GiB minimum only while running. Short execution keeps disk cost negligible; duration remains measured.                                                                       |
| Cloud Scheduler                       | USD 0.10/job/month, with three jobs free per billing account                                                                                                  | Five recovery schedules plus hourly key rotation add about USD 0.30/month when the billing account's free allowance is otherwise unused.                                                                             |
| Cloud Monitoring                      | Native platform metrics and notification channels have no fixed launch charge within the stated allowances                                                    | Eight alert policies use only Google-provided metrics. Alert-policy pricing is announced no sooner than September 2027 and is tracked below.                                                                         |
| GitHub Actions                        | Standard GitHub-hosted runners are free in this public repository                                                                                             | The existing drift workflow makes one synthetic health request every three hours and stores no artifact. Larger or self-hosted runners are not used.                                                                 |
| Cloud Logging                         | First 50 GiB/project/month free; then USD 0.50/GiB ingested, including 30-day storage                                                                         | Thirty-day retention and the narrow successful-healthcheck exclusion aim to keep launch logging free without hiding failures.                                                                                        |
| Secret Manager                        | Six active versions per billing account free; then USD 0.06/version-location/month; first 10,000 access operations free                                       | Nine initial active versions would add roughly USD 0.18/month before access overage. Metadata-only containers cost nothing.                                                                                          |
| VPC firewall rules                    | No charge                                                                                                                                                     | The custom VPC, routes, Private Google Access, and ordinary firewall rules have no fixed fee; network transfer can still be billed.                                                                                  |
| Budget, quotas, IAM, service accounts | No fixed product charge                                                                                                                                       | They reduce risk but do not cap every source of spend.                                                                                                                                                               |

Sources: [Cloud DNS pricing](https://cloud.google.com/dns/pricing),
[Artifact Registry pricing](https://cloud.google.com/artifact-registry/pricing),
[disk and snapshot pricing](https://cloud.google.com/compute/disks-image-pricing),
[Cloud Storage pricing](https://cloud.google.com/storage/pricing),
[Cloud Run pricing and examples](https://cloud.google.com/run/pricing),
[Cloud Scheduler pricing](https://cloud.google.com/scheduler/pricing),
[Cloud Monitoring pricing](https://cloud.google.com/products/observability/pricing),
[Cloud Logging pricing](https://cloud.google.com/logging/pricing),
[Secret Manager pricing](https://cloud.google.com/secret-manager/pricing), and
[VPC firewall pricing](https://cloud.google.com/firewall/pricing). The synthetic-check assumption
uses [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
and [scheduled-workflow behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule).
External mail assumptions use
[hosted Plunk pricing](https://www.useplunk.com/pricing) and its
[billing/cap documentation](https://docs.useplunk.com/concepts/billing).

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

The Cloud Run row includes the eight scheduled Authentication checks per day. Google can retain an
instance-billed service for up to 15 idle minutes after a request, so those checks create at most
about 60 allocated hours in a 30-day month before organic traffic. That fits inside the current
240,000 vCPU-second instance-based free tier for one vCPU by itself, but Cloud Run free usage is
aggregated by billing account and jobs or other services consume the same allowance. At current
rounded rates, traffic that keeps one 1 vCPU/512 MiB Authentication instance allocated continuously
can add approximately USD 45–55/month before allowances. That is a measured-usage trigger to revise
the worksheet or move post-response mail onto a request-bound or queued application path; it is not
included in the low-traffic launch range.

Google has announced alert-policy pricing no sooner than September 2027. At the published
USD 0.35 per metric reference, the current eleven references would add about USD 3.85/month plus
the small query-point charge if that model takes effect unchanged. This is not included in the 2026
range. Reprice before the effective date; consolidating conditions merely to save a few dollars must
not make alerts ambiguous or harder to own.

At four-hour cadence and 14-day lifecycle, logical retention contains at most 84 completed archives
per database. The capacity formula is therefore:

```text
logical retained GiB = 84 × aggregate compressed GiB of one JSON Keys + Authentication backup
```

At six aggregate backup sets per day, the bucket also receives about 180 aggregate writes each
30-day month. One monthly drill and each protected release read one aggregate set from the EU
multi-region into `europe-west1`. Each established release writes one pre-change and one
post-migration aggregate set and retains both for up to 14 days; first activation omits the
pre-change set because no source database exists. If `D` is the number of established releases and
`F` is `1` when first activation occurs in that month (otherwise `0`), the recurring logical-backup
estimate is:

```text
logical USD/month ≈ (84 × 0.026 + (180 + 2D + F) × 0.02
                    + (1 + D + F) × 0.02
                    + (2D + F) × (14 / 30) × 0.026)
                    × aggregate compressed GiB
                  ≈ (5.80 + 0.08D + 0.05F) × aggregate compressed GiB
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
- LLM/API usage or hosted SMTP/email provider charges. Hosted Plunk currently advertises no base fee
  and USD 0.001 per paid email with no branding, but it is externally billed and price-variable;
- warm Cloud Run instances, paid load balancing, WAF, CDN, Cloud NAT, an egress proxy, or a VPC
  connector;
- GitHub Actions runner charges if this repository becomes private or stops using standard hosted
  runners;
- multi-zone PostgreSQL high availability, PITR/WAL archival, or managed PostgreSQL;
- abnormal log volume, vulnerability scanning, or image storage outside the stated assumptions.

Authentication uses Cloud Run's direct managed public egress for TLS SMTP; JSON Keys has no public
egress path. No fixed-cost NAT, connector, proxy, or load balancer is included because none is
provisioned.

## Controls and update rule

The 60-unit monthly production-infrastructure budget spans the management and workload projects,
uses the billing account currency, alerts both human channels at current and forecasted
50/75/90/100%, and is alert-only. The USD worksheet remains the planning comparison. Hosted Plunk
has a separate operator-set transactional category cap because it is outside Google billing. Actual
Google brakes are maximum Cloud Run instances, regional
Cloud Run CPU/memory/Direct VPC quotas, the four-CPU Compute Engine quota, immutable image cleanup
review, bounded log retention, backup lifecycle, and validated disk sizes. Quotas can prevent
some scaling but cannot stop every billable API, transfer, storage, or compromised workload.

Update this worksheet in the same pull request when any of these changes:

- a minimum instance becomes nonzero;
- a VM machine type, disk type/capacity, region, zone count, NAT, connector, proxy, load balancer, or
  other fixed-cost resource changes;
- repository visibility or the runner class used by scheduled health changes;
- backup frequency/retention or observed compressed size leaves its assumption;
- measured Cloud Run, log, registry, transfer, or secret usage makes a range inaccurate;
- Google changes a material public unit price.

After deployment, replace assumptions with the prior 30-day billing report while retaining the unit
formula and the low/high uncertainty range. Never export a full OpenTofu plan or secret-bearing state
to a third-party cost service.
