# host-credentials

A one-shot loader that runs before PostgreSQL on the database hosts, and before the pgBackRest
server on the backup repository VMs.

1. It checks the VM's identity.
2. It reads the pinned pgBackRest TLS secret versions.
3. It validates the CRC32C checksum, the certificate chain, key usage and name.
4. It publishes `ca.pem` and `identity.pem` (mode 0400) atomically under `/run`.

It is published by `publish-rollout-verifier.yaml`; see
[Host tools](../../docs/runbooks/host-tools.md).
