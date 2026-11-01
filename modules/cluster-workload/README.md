# cluster-workload

Runs one long-lived gRPC or HTTP workload on the cluster: its Kubernetes service account, a
Deployment that Pod Security's restricted level admits, its Service, and a disruption budget or an
autoscaler when it runs more than one pod. The autoscaler reads CPU, and a gauge the pods serve on a
metrics port when the caller names one. A server can serve TLS from its certificate's Secret, which
its probes then read over TLS too. Its pods trust their database's CA and the services CA beside the
system roots, and carry a service token for each service they call. Each service's workloads in the cluster root
call it.
