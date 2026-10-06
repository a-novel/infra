# Production cost worksheet

Google Cloud public USD list prices were reviewed on 2026-08-27; Workspace SMTP assumptions
were updated on 2026-09-06 and warm Cloud Run instance pricing on 2026-09-09.
The two-host inventory was updated on 2026-09-11 using those earlier unit assumptions; reprice it before apply. This is a
transparent planning model, not a quote or an invoice forecast. Google bills actual usage,
aggregates some free tiers by
billing account, converts non-USD invoices at its applicable rates, and can change prices. Recheck
the linked pages and the [Google Cloud Pricing Calculator](https://cloud.google.com/products/calculator)
before the first apply and before any fixed-cost shape change.

The launch tables are a baseline model, not an inventory of the current split-project deployment.
The [native-backup coexistence](#native-backup-coexistence) calculation below is additional to that
baseline. Live adoption evidence and remaining measurement limits belong in
[#190](https://github.com/a-novel/infra/issues/190).

## Cost profiles

| Profile          | What exists                                                                                                                                                                              | Expected USD/month before tax |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------: |
| Foundation only  | Workload project, VPC/firewalls/routes, three private DNS zones, identities, registry, quotas, budget, bounded logs, two on-demand `e2-medium` VMs, each with 20/50 GiB SSD-backed disks |               **about 65–80** |
| Launch           | Foundation, daily disk snapshots, four-hour logical backups, two services with one warm instance each, and short jobs                                                                    |                   **130–155** |
| Capacity horizon | Larger database host/storage and additional services with one warm instance each                                                                                                         |  **Reprice before expansion** |

The foundation-only range is the cost of applying the code while both database components remain
disabled. Both VMs stay on but idle, and no PostgreSQL container runs. Compute and provisioned disks
are the fixed cost; three DNS zones add approximately USD 0.60/month. The launch row adds active
database images, 14-day logical retention, daily snapshots, five scale-to-zero recovery jobs, four
short application jobs, and one warm instance for each of the two production services.
Changes land through the protected foundation and release workflows.

## Current unit assumptions

| Unit                                  | List-price assumption used                                                                                                                                  | Worksheet effect                                                                                                                                     |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Cloud DNS private zone                | USD 0.20/zone/month for the first 25 zones                                                                                                                  | Three zones = USD 0.60/month.                                                                                                                        |
| Cloud DNS regular queries             | USD 0.40 per million for the first billion monthly queries                                                                                                  | Low launch traffic should remain well below USD 1/month.                                                                                             |
| Artifact Registry storage             | First 0.5 GiB per billing account free; then about USD 0.10/GiB-month                                                                                       | Immutable images remain inexpensive; dry-run cleanup exposes growth before deletion is enabled.                                                      |
| Compute Engine `e2-medium`            | Rounded on-demand `europe-west1` estimate of USD 25–30/month for one continuously running VM                                                                | Each database group has target size one and no autoscaler, so this cost continues while the foundation exists.                                       |
| Balanced Persistent Disk              | About USD 0.10/GiB-month in `europe-west1`                                                                                                                  | Two 50 GiB data disks plus two 20 GiB boot disks total 140 GiB, about USD 14/month. Provisioned, not used, capacity is billed.                       |
| Same-region standard snapshots        | USD 0.000068493/GiB-hour for stored snapshot data                                                                                                           | The globally scoped snapshots store data in `europe-west1` as the inexpensive fast local-recovery layer; billing follows changed snapshot bytes.     |
| EU multi-region Cloud Storage         | About USD 0.026/GiB-month, plus USD 0.02/GiB for each replicated write and for reads into `europe-west1`                                                    | The logical-backup formula below includes steady retention, scheduled writes, the monthly drill, and one backup/restore verification per release.    |
| Cloud Run services                    | JSON Keys uses request-based CPU; Authentication uses instance-based CPU so detached mail can drain. Production minimum `1`, maximum `3`, concurrency `20`. | About USD 59/month for the two warm instances before free tiers and traffic; recovery minimum stays `0`.                                             |
| Cloud Run jobs                        | Instance-based billing while a task runs; Preview ephemeral disk is USD 0.000109589/GiB-hour in `europe-west1`                                              | Backup and restore use the supported 10 GiB minimum only while running. Short execution keeps disk cost negligible; duration remains measured.       |
| Cloud Scheduler                       | USD 0.10/job/month, with three jobs free per billing account                                                                                                | Five recovery schedules plus hourly key rotation add about USD 0.30/month when the billing account's free allowance is otherwise unused.             |
| Cloud Monitoring                      | Native platform metrics and notification channels have no fixed launch charge within the stated allowances                                                  | Eight alert policies use only Google-provided metrics. Alert-policy pricing is announced no sooner than September 2027 and is tracked below.         |
| GitHub Actions                        | Standard GitHub-hosted runners are free in this public repository                                                                                           | The existing drift workflow makes one synthetic health request every three hours and stores no artifact. Larger or self-hosted runners are not used. |
| Cloud Logging                         | First 50 GiB/project/month free; then USD 0.50/GiB ingested, including 30-day storage                                                                       | Thirty-day retention and the narrow successful-healthcheck exclusion aim to keep launch logging free without hiding failures. OTLP logs count here.  |
| Cloud Trace                           | First 2.5 million spans per billing account each month free; then USD 0.20 per million spans                                                                | Both services sample every request at roughly ten spans each, so the free allotment covers about 250,000 requests a month.                           |
| Secret Manager                        | Six active versions per billing account free; then USD 0.06/version-location/month; first 10,000 access operations free                                     | Seven initial active versions add roughly USD 0.06/month before access overage. Metadata-only containers cost nothing.                               |
| VPC firewall rules                    | No charge                                                                                                                                                   | The custom VPC, routes, Private Google Access, and ordinary firewall rules have no fixed fee; network transfer can still be billed.                  |
| Budget, quotas, IAM, service accounts | No fixed product charge                                                                                                                                     | They reduce risk but do not cap every source of spend.                                                                                               |

Sources: [Cloud DNS pricing](https://cloud.google.com/dns/pricing),
[Artifact Registry pricing](https://cloud.google.com/artifact-registry/pricing),
[disk and snapshot pricing](https://cloud.google.com/compute/disks-image-pricing),
[Cloud Storage pricing](https://cloud.google.com/storage/pricing),
[Cloud Run pricing and examples](https://cloud.google.com/run/pricing),
[Cloud Scheduler pricing](https://cloud.google.com/scheduler/pricing),
[Cloud Monitoring pricing](https://cloud.google.com/products/observability/pricing),
[Cloud Logging pricing](https://cloud.google.com/logging/pricing),
[Cloud Trace pricing](https://cloud.google.com/stackdriver/pricing#trace-costs),
[Secret Manager pricing](https://cloud.google.com/secret-manager/pricing), and
[VPC firewall pricing](https://cloud.google.com/firewall/pricing). The synthetic-check assumption
uses [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
and [scheduled-workflow behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule).
External mail uses the existing Workspace subscription and its
[SMTP relay service](https://knowledge.workspace.google.com/admin/gmail/advanced/route-outgoing-smtp-relay-messages-through-google).

## Launch formula

| Component                   | Planning assumption                                                                                              |   USD/month |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------- | ----------: |
| Database compute            | Two on-demand `e2-medium` VMs running continuously in `europe-west1`                                             |       50–60 |
| Persistent storage          | 100 GiB data plus 40 GiB boot storage, all SSD-backed `pd-balanced`                                              |       14–16 |
| Backups and snapshots       | Two small databases, at most 0.5 GiB combined per restore point, plus seven daily same-region snapshots per disk |         1–5 |
| Cloud Run services and jobs | Two warm instances plus short migrations, initialization, rotation, backup, and restore checks                   |       60–65 |
| Registry and control plane  | DNS, small state/receipt/image storage, secrets, and bounded logs                                                |         1–4 |
| **Expected total**          | Low traffic, two warm instances, no paid edge                                                                    | **130–155** |

The database compute row is intentionally a rounded calculator assumption because Compute Engine
prices vary by region, sustained-use eligibility, calendar hours, and pricing-model changes. The
database-host change must refresh the exact calculator estimate before apply. The upper bound leaves
room for snapshot churn and early operational logs without pretending those costs are fixed.

The Cloud Run row includes one warm 1 vCPU/512 MiB instance for each production service. Using
Tier 1 on-demand USD rates for `europe-west1` and a 30-day month, before free tiers:

```text
Authentication (instance billed): 2,592,000 × (0.000018 + 0.5 × 0.000002) = USD 49.25
JSON Keys (request billed, idle):  2,592,000 × (0.0000025 + 0.5 × 0.0000025) = USD 9.72
Combined warm baseline: USD 58.97/month
```

Active requests, startup time, extra autoscaled instances, and jobs add usage; free-tier credits
are shared across the billing account. The minimum is set at service level so tagged candidate
revisions do not each reserve an idle instance. Recovery drills retain minimum zero and jobs run
only when invoked. Google can restart minimum instances, so this latency setting is not an uptime
guarantee. See [minimum-instance behavior and billing](https://docs.cloud.google.com/run/docs/configuring/min-instances).

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
30-day month. One monthly drill reads one aggregate set. A routine service release reads only its selected database's set from the EU
multi-region into `europe-west1`. Each selected database release writes one pre-change and one
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

## Native-backup coexistence

The approved JSON Keys pilot uses one existing `e2-micro` repository with a 20 GiB `pd-standard`
boot disk in `europe-west1`, the existing database host, and a management-owned EU multi-region Standard
bucket. It adds no database VM, repository data disk, public IP, NAT or Cloud Scheduler job.
Logical backups and daily snapshots remain billable throughout coexistence. Authentication's
protection is unchanged.

Keep a dated EUR worksheet for the following quantities. Public default-consumption prices read on
2026-10-06 give EUR 0.0352/GiB-month for standard persistent disk (SKU `D973-5D65-BAB2`) and
EUR 0.02288/GiB-month for EU multi-region Standard storage (SKU `EC40-8747-D6FF`). These exclude operations,
transfer and tax; verify the SKU region, tiers and billing-account terms before an apply.
See Google's [Pricing API](https://docs.cloud.google.com/billing/docs/reference/pricing-api/rest/v2beta/skus.price/get),
[VM pricing](https://cloud.google.com/products/compute/pricing/general-purpose) and
[storage pricing](https://cloud.google.com/storage/pricing).

```text
gross native EUR/month = running repository hours × exact e2-micro hourly rate
                       + 20 × standard-disk GiB-month rate
                       + average retained GiB × EU-storage GiB-month rate
                       + requests, transfers, secrets, registry and observability usage
net additional EUR/month = gross native cost − verified retired legacy cost
```

The boot disk contributes approximately EUR 0.70/month at that rate. Each 100 average retained GiB
adds approximately EUR 2.29/month for storage alone. No US free-tier disk credit is assumed.
Revalidate the regional **shared-core machine
price**; fractional CPU capacity is not an independently verified VM billing rate. The EUR 10–15
additional per-service ceiling is an acceptance limit, not a verified bill or an automatic cap.

Inventory live, noncurrent and soft-deleted bytes separately, including catalogs, WAL and incomplete
attempts. Separate synthetic acceptance prefixes from production growth, but include both in the
bill. Seven-day retention is a minimum protection window, not a seven-day storage ceiling:
automatic expiry and lifecycle cleanup are off. Measure at least one full/differential cycle,
WAL/day, durations and resource headroom; compare the estimate with actual billing before adoption.
Include the existing custom log metric's shared ingestion allowance and current alert pricing.

Credit no savings yet. Eventually count only the selected service's retired logical job executions,
schedules, transfers and storage after retained objects expire. Database hosts, other services,
shared monitoring and snapshots are not automatically removable backup costs. Replace the logical
jobs' release/maintenance callers before retirement and preserve historical restore readers/images.
Both deployed backup buckets use EU multi-region storage. Include replication writes and reads into
`europe-west1`; do not price them as single-region Belgium buckets. Multi-region object storage alone
does not establish a tested regional recovery procedure.

## Capacity-horizon formula

| Component                   | Planning assumption                                                                                 |                    USD/month |
| --------------------------- | --------------------------------------------------------------------------------------------------- | ---------------------------: |
| Database compute            | Per database: one on-demand `e2-standard-2`                                                         |                        50–60 |
| Persistent storage          | Per database: 150 GiB balanced data disk plus SSD boot disk                                         |                        15–18 |
| Backups and snapshots       | `84 ×` aggregate compressed current backup size, at most 3 GiB combined, plus same-region snapshots |                        15–25 |
| Cloud Run services and jobs | One warm instance per future service plus short jobs                                                |          Reprice per service |
| Registry and control plane  | State/receipts, registry, secrets, scheduler, private DNS, and bounded logs                         |                          2–7 |
| **Expected total**          | Depends on the future service mix and billing modes                                                 | **Reprice before expansion** |

The capacity horizon must be repriced before expansion: every additional production service needs
its own warm-instance allowance, based on its CPU/memory and billing mode. Use the unit formula
above; the service mix is not yet configured, so no total is quoted.

Each additional database needs its own VM, SSD-backed data/boot disks, snapshots, and quota
allowance. Size and reprice each independently before expanding the foundation.

## Explicit exclusions

These usage-dependent or product decisions are not inside the ranges above:

- tax, non-USD currency conversion, domains, and a custom edge;
- internet data transfer and cross-region transfer beyond the scheduled logical-backup writes and
  monthly restore included above;
- LLM/API usage and the existing Google Workspace subscription. SMTP relay adds no per-message
  charge or additional mailbox for the configured unregistered sender; any future paid
  authentication mailbox adds its Workspace seat cost;
- additional autoscaled Cloud Run instances, paid load balancing, WAF, CDN, Cloud NAT, an egress proxy, or a VPC
  connector;
- GitHub Actions runner charges if this repository becomes private or stops using standard hosted
  runners;
- multi-zone PostgreSQL high availability, PITR/WAL archival, or managed PostgreSQL;
- abnormal log volume, vulnerability scanning, or image storage outside the stated assumptions.

Authentication uses Cloud Run's direct managed public egress for TLS SMTP; JSON Keys has no public
egress path. No fixed-cost NAT, connector, proxy, or load balancer is included because none is
provisioned.

## Controls and update rule

Opt-in service-project shells add project/API/IAM controls, bounded logs, and Shared VPC attachments.
They create no VM, disk, Cloud Run instance, NAT, connector, or load balancer. The existing budget
includes their project numbers without changing its amount or thresholds. Project separation does
not multiply billing-account free tiers. Reprice the actual service resources and any temporary
migration overlap before activating a workload in a new project; the current launch estimate remains
the existing two-service deployment. See [Shared VPC pricing](https://cloud.google.com/vpc/docs/shared-vpc#pricing).

The 60-unit monthly production-infrastructure budget spans the management and workload projects,
uses the billing account currency, alerts both human channels at current and forecasted
50/75/90/100%, and is alert-only. The warm-instance baseline can exceed this existing threshold
once database and storage costs are included. Review the budget in the billing account currency
before rollout; this configuration change does not raise it automatically.
The USD worksheet remains the planning comparison. Workspace
relay has shared organization sending limits and abuse controls, documented in the
[SMTP runbook](../runbooks/configure-hosted-smtp.md). Its subscription is separate from Cloud billing.
Actual Google brakes are maximum Cloud Run instances, single-task jobs, regional
Cloud Run CPU/memory quotas, the four-CPU Compute Engine quota, immutable image cleanup
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
