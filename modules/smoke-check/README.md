# smoke-check

A private gRPC service's smoke job, which calls its status RPC from inside the VPC as an identity
that may only invoke it. It runs on every new image, script or identity, and again once a planned
downtime clears.

`smoke.sh` is the health check every service shares. The smoke jobs run it over gRPC, and the
`health` action runs it over HTTP against Authentication and Studio, which is public and receives no
token. On the cluster, the cluster root's smoke Jobs and health CronJobs run it in each service's
image, over plaintext, with the service token the kubelet projects. It retries every five seconds
for two minutes, since a fresh invoker grant takes that long to apply, and skips once a planned
downtime has started.
