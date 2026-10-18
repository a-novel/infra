# service-runtime

One service's footprint in one trust-zone project:

- its runtime identity, which the main server runs as, and the secrets it may read;
- one identity per other workload, such as a job or the smoke check, reading only the secrets it
  mounts;
- its `production` and `tooling` image repositories, which its database host may read;
- its operations alert channel.
