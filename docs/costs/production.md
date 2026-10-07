# Production cost worksheet

This worksheet describes the two-service native-backup shape accepted on 7 October 2026.
It replaces the retired logical-job/snapshot launch model, which is not a current production estimate.
Other-service adoption and capacity expansion require their own reviewed plan.

## Billable inventory

| Component             | Current shape                                                                                                                            | Cost driver                                                                             |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| PostgreSQL            | One private `e2-medium` per service, each with a 50 GiB `pd-balanced` data disk and 20 GiB `pd-balanced` boot disk                       | VM hours and provisioned disk capacity, even while idle                                 |
| Native repositories   | One private `e2-micro` per service with a 20 GiB `pd-standard` boot disk                                                                 | VM hours and boot storage; no repository data disk                                      |
| Native backup storage | Separate management-owned EU multi-region buckets                                                                                        | Live, noncurrent and soft-deleted bytes; WAL, catalogs, requests and transfers          |
| Cloud Run             | Existing Authentication REST and JSON Keys gRPC, each with one warm instance and a maximum of three; short application/verification jobs | Billing mode, CPU/memory, active time, requests and autoscaling                         |
| Scheduling            | Existing JSON Keys rotation schedule; native backups use systemd timers                                                                  | Scheduler usage for rotation; backup timers execute on the existing hosts               |
| Control plane         | State, receipts, private DNS, regional image repositories, secret versions, logs, metrics and alerts                                     | Storage, requests and observability usage                                               |
| Historical backups    | Locked objects in the former logical-backup bucket                                                                                       | Storage until eligible deletion; no logical jobs, schedules or snapshot policies remain |

Native backup expiry retains full chains for 14 days. Object retention and versioning can keep
bytes billable after pgBackRest expires a chain; retention is not a maximum storage-size guarantee.
The follow-ups below measure those layers separately. Each service keeps its own database and
repository; the trust-zone split does not duplicate a service's database.

## Calculation

Use the billing account's currency and exact regional SKUs, not a converted historical USD total:

```text
production cost = database VM hours and provisioned disks
                + repository VM hours and provisioned boot disks
                + retained backup/WAL bytes, requests and transfers
                + Cloud Run services and jobs
                + registry, state, secrets, networking and observability usage

net additional native cost = gross native cost − measured retired backup cost
```

The approved EUR 10–15 additional-per-service native-backup limit is a planning boundary,
not a verified invoice or an automatic billing cap. Do not derive a shared-core VM's price
from fractional CPU arithmetic or assume a US free-tier allowance applies in Belgium.
Credit removed job/snapshot costs only from measured billing; historical objects remain billable
until deleted.

Google's [VM pricing](https://cloud.google.com/products/compute/pricing),
[disk pricing](https://cloud.google.com/compute/disks-image-pricing),
[Cloud Storage pricing](https://cloud.google.com/storage/pricing),
[Cloud Run pricing](https://cloud.google.com/run/pricing) and
[Observability pricing](https://cloud.google.com/products/observability/pricing)
are the authoritative unit-price references. Recheck location, currency, billing terms,
shared free tiers and tax before applying a capacity or retention change.
EU multi-region replication writes and reads into `europe-west1` are not single-region storage.

## Verification follow-ups

| Work                                                        | Deadline                           | Evidence owner                                      |
| ----------------------------------------------------------- | ---------------------------------- | --------------------------------------------------- |
| Natural weekly-full outcomes for both services              | 12 October 2026                    | [#637](https://github.com/a-novel/infra/issues/637) |
| Eligible historical objects and empty-bucket retirement     | 14 October 2026, after 12:00 Paris | [#638](https://github.com/a-novel/infra/issues/638) |
| Full-chain expiry, WAL/noncurrent growth and projected cost | 21 October 2026                    | [#639](https://github.com/a-novel/infra/issues/639) |
| Settled October infrastructure and rehearsal billing        | 6 November 2026                    | [#640](https://github.com/a-novel/infra/issues/640) |

Manual full/differential, archive verification and isolated SQL restores have passed.
They are not natural scheduled outcomes or a month's billing measurement. Acceptance evidence
is in [#190](https://github.com/a-novel/infra/issues/190); future observations are grouped under
[#636](https://github.com/a-novel/infra/issues/636).

## Controls and update rule

The configured budget is alert-only; maximum instances, job limits, quotas and fixed disk sizes
bound some usage but do not cap every billable API or storage/transfer charge.
Project separation does not multiply billing-account free tiers.
There is no added public IP, NAT, VPC connector, proxy, load balancer or Kubernetes layer.
The existing Workspace subscription and SMTP organization limits remain separate from Cloud billing.

Update this worksheet with any VM/disk, warm-instance, region, retention, network, runner-class
or material price change. Include temporary overlap and recovery capacity in its reviewed plan.
Each additional service needs its own database, repository and workload estimate.
Use measured billing to replace assumptions, with uncertainty stated.
Never upload a secret-bearing state or saved plan to a third-party cost service.
