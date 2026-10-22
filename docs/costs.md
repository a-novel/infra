# Costs

This document is about what production pays for, and what bounds each cost.

| Component         | Shape                                                                                                        | Main cost driver                   |
| ----------------- | ------------------------------------------------------------------------------------------------------------ | ---------------------------------- |
| Database hosts    | 2 × `e2-medium` and 1 × `e2-standard-2` (GenAI), 50 GiB `pd-balanced` data + 20 GiB `pd-balanced` boot each  | VM hours and disks, even when idle |
| Backup hosts      | 2 × `e2-micro`, 20 GiB `pd-standard` boot each                                                               | VM hours                           |
| Backup storage    | EU multi-region buckets, 14-day full chains, plus versioning and soft delete                                 | Stored bytes, including WAL        |
| Rollout snapshots | Each rollout's data-disk snapshot, until a later rollout finds it older than 14 days                         | Stored bytes                       |
| Cloud Run         | JSON Keys 1–2 instances, Authentication 1, GenAI gRPC 0–4 and sweep 0–1; Authentication CPU always allocated | Instance time                      |
| Internet egress   | Cloud NAT with one reserved address, and the egress allowlist's Cloud NGFW Standard rules                    | NAT hours per instance served      |
| Control plane     | State, registries, secrets, private DNS (3 zones), logs (30 days), alerts                                    | Small, usage-based                 |

Backup storage only grows today. The buckets keep every version of the objects pgBackRest expires,
because `noncurrent_cleanup` is off in bootstrap's `terraform.tfvars`. Turning it on deletes those
versions 7 days after they are replaced.

The budget is **150 units** of the billing account's currency a month, for the four production
projects. It alerts at 50, 75, 90 and 100%, actual or forecast, and caps nothing. Quotas, maximum
instances and fixed disk sizes bound most usage, but not storage or requests. Every project that
runs Cloud Run has its own CPU and memory quota, and each service root checks its maximum instances
against it.

Recovery drill projects are billed to the same account but sit outside the budget. Delete each one
as soon as its drill ends.

Native backups are estimated at EUR 10–15 extra per service per month. Real figures come from the
billing report.

Internet egress is estimated at USD 11–15 a month. The address costs USD 0.005 an hour. NAT costs
USD 0.0014 an hour for each instance it serves, which includes the database and repository VMs the
firewall keeps off the internet, and probably each Cloud Run instance on the subnet. The bytes that
NAT and the allowlist process add cents.

Update this page when a VM, disk, warm instance, region or retention setting changes. Prices:
[Compute](https://cloud.google.com/products/compute/pricing),
[disks](https://cloud.google.com/compute/disks-image-pricing),
[Cloud Storage](https://cloud.google.com/storage/pricing),
[Cloud Run](https://cloud.google.com/run/pricing), [Cloud NAT](https://cloud.google.com/nat/pricing),
[Cloud NGFW](https://cloud.google.com/firewall/pricing).
