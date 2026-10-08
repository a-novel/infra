# Costs

| Component      | Shape                                                                                          | Main cost driver                   |
| -------------- | ---------------------------------------------------------------------------------------------- | ---------------------------------- |
| Database hosts | 2 × `e2-medium`, 50 GiB `pd-balanced` data + 20 GiB boot each                                  | VM hours and disks, even when idle |
| Backup hosts   | 2 × `e2-micro`, 20 GiB `pd-standard` boot each                                                 | VM hours                           |
| Backup storage | EU multi-region buckets, 14-day full chains, plus versioning and soft delete                   | Stored bytes, including WAL        |
| Cloud Run      | JSON Keys and Authentication, 1 warm instance each, max 3; Authentication CPU always allocated | Instance time                      |
| Control plane  | State, registries, secrets, private DNS (3 zones), logs (30 days), alerts                      | Small, usage-based                 |

There is no NAT, load balancer, public IP or Kubernetes.

The budget is **60 units** a month. It only alerts, at 50, 75, 90 and 100%, actual or forecast; it
caps nothing. Quotas, maximum instances and fixed disk sizes bound most usage, but not storage or
requests.

Native backups were approved with a planning ceiling of EUR 10–15 extra per service per month. Real
figures come from billing; follow-ups #637–#640 measure them.

Update this page when a VM, disk, warm instance, region or retention setting changes. Prices:
[Compute](https://cloud.google.com/products/compute/pricing),
[disks](https://cloud.google.com/compute/disks-image-pricing),
[Cloud Storage](https://cloud.google.com/storage/pricing),
[Cloud Run](https://cloud.google.com/run/pricing).
