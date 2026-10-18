# smoke-check

A private gRPC service's smoke job, which calls its status RPC from inside the VPC after every new
image, as an identity that may only invoke it.

`smoke.sh` is the health check every service shares: the smoke jobs run it over gRPC, and the deploy
and drift workflows run it over HTTP against Authentication. It retries for two minutes, since a
fresh invoker grant takes that long to apply, and skips once a planned downtime has started.
