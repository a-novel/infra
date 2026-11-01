# service-runtime

One service's footprint in the workload project, now that the cluster runs its workloads:

- its `production` image repository, which the cluster runs every release from, and its `tooling`
  repository, which retires with the database hosts (a-novel/infra#1208). Its database host may read
  both;
- its operations alert channel.
