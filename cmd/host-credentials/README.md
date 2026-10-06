# Native-backup host credentials

One-shot TLS credential delivery for service-owned native backups. CI builds and scans this image. Its
[protected publisher](../../docs/runbooks/publish-rollout-verifier.md) requires
separate activation and approval. Publishing the image populates no secret
and changes no running host or backup schedule.

The one-shot command uses Google's Secret Manager client and the VM's attached
identity. It does not use local ADC, issue certificates, rotate credentials, or
run a credential service. The disabled [repository](../../environments/service-foundation/README.md#prepared-native-runtime)
and [database](../../modules/database-runtime/README.md) units own
ordering and lifecycle. Their foundation owners control activation.

## Contract

All arguments except `--zone` are required; `--help` describes them. `--service` selects
`json-keys` or `authentication` and binds secret names and shared-project identities.
The management project must
be its **numeric project number**, matching Secret Manager's canonical response
name. CA and identity versions must be positive numeric versions, never aliases.

| Endpoint     | Required identity in `--workload-project` | Identity secret                              | `--name`                                 |
| ------------ | ----------------------------------------- | -------------------------------------------- | ---------------------------------------- |
| `database`   | `agora-database`                          | `production-<service>-pgbackrest-database`   | Authorized client certificate CN         |
| `repository` | `agora-backup-repository`                 | `production-<service>-pgbackrest-repository` | Server DNS name used by database clients |

Without `--zone`, these dedicated-project identities are unchanged. `--zone=private`
requires `agora-<service>-database` for the database or `agora-pgbr-<service>`
for the repository, in the same workload project. Other zones are rejected.
The attached metadata identity must match exactly; callers cannot supply an arbitrary account.

Both endpoints read `production-<service>-pgbackrest-ca`. The CA payload contains
public CA certificates only. The identity payload contains the endpoint's leaf
certificate, optional intermediate certificates, and exactly one unencrypted
private key. The loader checks exact returned versions, CRC32C, certificate/key
matching, trust, validity, usage, and the selected CN or DNS name before writing.
The endpoint certificate must not be a CA. Google handles authentication,
transport, and bounded request retries; the command has a two-minute deadline.
When services share a CA, give their clients distinct CNs and authorize only the matching
CN/stanza on each repository. Secret selection alone does not isolate TLS peers.

## Host integration prerequisites

1. Supply reviewed versions and an artifact verified through the protected
   publication/provenance path. That publication path is not enabled here.
2. Create a private, ephemeral parent directory on the host, owned by the same
   UID as the loader and eventual pgBackRest consumer, with mode `0700`. The
   output must be a fresh child directory. Parent ancestors and the host are
   trusted; this is not a defence against a compromised host administrator.
3. Run the loader with only that parent writable. It creates `ca.pem` and
   `identity.pem` with mode `0400` inside a `0700` directory and publishes the
   pair atomically. Existing outputs, including concurrent publication, are
   never replaced. Only its own temporary staging directory is cleaned on error.
4. Start the consumer only after successful delivery; mount only the resulting
   directory read-only. pgBackRest uses `identity.pem` for both certificate and
   key options. Remove ephemeral credentials after consumers stop, including
   abandoned staging directories after abrupt termination. Retrying against
   existing output requires a deliberate stopped-consumer lifecycle, not an
   overwrite option.

Secret Manager IAM applies to the secret, not just the selected version. Disabling
a version does not revoke already loaded TLS credentials. Renewal, revocation,
expiry monitoring, and restart coordination must be defined before activation.
Certificate validation also does not confine an authenticated pgBackRest client:
filesystem, network, metadata, and attached-identity restrictions remain separate
host requirements. PostgreSQL must remain unable to reach VM credentials.
The [native transport proof](../../proofs/pgbackrest/README.md#native-repository-transport)
also shows that an authorized client can read a server-readable synthetic file outside its
repository. Private file modes and read-only mounts are not confidentiality barriers against
that process. The loader's safe delivery contract does not establish server-key confinement;
the database client and repository process share the accepted per-service backup-writer trust
boundary. Recovery authority remains separate. Prepared host wiring stays disabled pending the
effective IAM/egress and lifecycle proofs.

## Checks

Table-driven tests use the official client against a local HTTP server and
ephemeral test certificates. They exercise delivery, integrity failures,
certificate identity/usage failures, private output permissions, and concurrent
no-overwrite publication without cloud access. The shared image action builds
and scans this loader and the native restore worker; their shared
publisher retains separate opt-ins and protected approval.
