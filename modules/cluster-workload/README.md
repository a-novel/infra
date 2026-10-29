# cluster-workload

Runs one long-lived gRPC or HTTP workload on the cluster: its Kubernetes service account, a
Deployment that Pod Security's restricted level admits, its Service, and a disruption budget or an
autoscaler when it runs more than one pod. Its pods trust their database's CA beside the system
roots, and carry a service token for each service they call. Each service's workloads in the
cluster root call it.
