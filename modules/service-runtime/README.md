# service-runtime

One service's footprint in one trust-zone project:

- its runtime identity, which the main server runs as, and the secrets it may read;
- one identity per other workload, such as a job or the smoke check, reading only the secrets it
  mounts;
- its `production` and `tooling` image repositories;
- its operations alert channel;
- the health check every service shares: its smoke job runs it over gRPC, and the deploy and
  drift workflows run it over HTTP against Authentication. It retries for two minutes, since a fresh
  invoker grant takes that long to apply.
