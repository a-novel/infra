# smoke-check

`smoke.sh` is the health check every service shares. The cluster root's smoke Jobs and health
CronJobs run it in each service's image, over TLS verified against the services CA, with the service
token the kubelet projects. It retries every five seconds for two minutes, and skips once a planned downtime has
started.
