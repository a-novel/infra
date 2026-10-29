# cluster-workload

Runs one long-lived gRPC workload on the cluster: its Kubernetes service account, a Deployment that Pod
Security's restricted level admits, its Service, and a disruption budget or an autoscaler when it
runs more than one pod. Each service's workloads in the cluster root call it.
