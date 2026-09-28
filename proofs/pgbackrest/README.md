# Disposable pgBackRest proof

Evaluation for [the backup-owner comparison](https://github.com/a-novel/infra/issues/190),
not a production backup implementation. The Go file is a test-only driver for native commands;
it is not linked into `infra`. The image uses each service's published PostgreSQL and pgBackRest,
adding only the test driver and an incompatible PostgreSQL major. No cloud resources,
credentials, existing data, schedules, or retention policies are used;
no production image is published or deployed.

## Run locally

From the repository root:

```sh
a-novel build --type=podman -y
podman run --rm --network=none --read-only --cap-drop=all \
  --security-opt=no-new-privileges --cpus=1 --memory=2g --pids-limit=128 \
  --tmpfs=/tmp:rw,size=1g,mode=1777 --timeout=660 \
  ghcr.io/a-novel/infra/pgbackrest-proof:local
```

The default selects JSON Keys. To exercise Authentication with the same driver (the CLI has no
build-argument option), build the other named stage and repeat the run command above:

```sh
podman build --format docker -f builds/pgbackrest-proof.Dockerfile \
  --build-arg DATABASE_SERVICE=authentication \
  -t ghcr.io/a-novel/infra/pgbackrest-proof:local .
```

The local tag is built, never pushed. All data lives in container tmpfs and disappears on exit.
There are no host mounts or published ports. The process runs as `postgres`, using peer-authenticated
Unix sockets; host authentication is SCRAM, not trust. Normal Go tests skip this package unless
`INFRA_PGBACKREST_PROOF=1`; the proof image sets it and CI runs both variants offline.
The Dockerfile owns the two SemVer selections; Renovate's native Dockerfile manager updates them.

The image has advisory findings below. Keep it restricted to this synthetic, offline test.
Do not pass credentials, mount real data, enable networking, or use it as a deployment artifact.

## What the test establishes

| Scenario               | Native behavior checked                                                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Full backup            | Restore into a clean directory; verify the row, role, and a real `uuid-ossp` function call through SQL.                                           |
| Point-in-time recovery | Restore a named point after a committed write; exclude the subsequent write. Wait for recovery to finish, not merely for read-only SQL readiness. |
| Interrupted copy       | Stop pgBackRest after backup data starts copying. Its catalog must remain unchanged and the earlier full backup must still restore.               |
| Missing/corrupt WAL    | Removing or corrupting a required archived segment makes `archive-get` fail and prevents the restored server from becoming ready.                 |
| Incompatible major     | PostgreSQL 17 refuses the restored PostgreSQL 18 data directory with its native incompatibility error.                                            |
| Retention              | Retain two full backups and a dependent differential. Restore the differential and newest full; the expired full is no longer selectable.         |
| Repository integrity   | Run native `verify` over the retained repository.                                                                                                 |

The cases intentionally share one evolving repository and stop on the first failure. This is not a
coverage suite for pgBackRest internals. Its output includes native catalog sizes, repository bytes,
restore-through-SQL duration and cgroup resource counters when available.

Interruption uses `pgbackrest --force stop` followed by `start`, not a bespoke process coordinator.
An exploratory parent-only SIGTERM left a worker holding the backup lock. A future VM/container
integration must test its actual shutdown path; parent exit is not evidence that all work stopped.

This is POSIX storage evidence, **not** proof of interrupted GCS uploads, GCS permissions, locked
retention, generation selection, host-loss recovery, or the production 6-hour RPO / 90-minute RTO.
The proof runs each image's extension initialization SQL and checks that its PostgreSQL, `uuid-ossp`
and pgBackRest binaries survive installation of the negative-test server unchanged. Shared libraries
are not covered by those checks. It does not exercise the original entrypoints, application
migrations, historical images, or native backup integration on the actual COS host.

### Native repository transport

`TestRepositoryTLS` reuses the recovery driver with a native repository server and temporary test
certificates on container loopback. Both service-image variants check backup/WAL transfer and SQL
recovery; a CA-signed but unauthorized client, wrong stanza and untrusted server must fail, with
authorized positive controls. A stopped server prevents restore, and an explicit retry of the same
set succeeds after restart. No external network, credential proxy or new runtime dependency is used.
Each endpoint supplies its certificate and private key from one standard PEM file, passed to both
native options. This verifies the single-version identity format in the
[disabled custody contract](../../bootstrap/README.md#disabled-tls-credential-custody); no real
credential is issued or delivered, and renewal remains a separate activation gate.

**TLS is authentication, not a fixed repository policy.** `Limit/ClientOverridesRepository`
demonstrates that an authorized client can override `repo1-path` and list a synthetic directory
outside the configured repository. It also reads an owner-readable (`0400`) synthetic file through
`repo-get`; removing read permission makes that read fail, while normal repository listing still
works. The [native protocol implementation](https://github.com/pgbackrest/pgbackrest/blob/release/2.59.1/src/protocol/helper.c)
loads client-supplied parameters before checking the authorized stanza. A green test records this
limitation; it does not endorse that access or establish the effect of every possible override.

Read-only mounts protect integrity, not confidentiality from the process that must read them.
In particular, `0400` alone cannot hide the server's PEM identity from an authorized native client
running through that process. This test reads only synthetic probe data, not credentials. Both
endpoints share a user and container; separate mounts, Docker/COS isolation, GCS options and
metadata access are not established by this proof.

The accepted code-only integration treats the service's database client and repository process as
one backup-writer trust boundary, with independent recovery authority. The
[prepared host runtime](../../environments/service-foundation/README.md#prepared-native-runtime)
remains disabled. Its effective filesystem, egress and IAM limits need a separate live proof;
PostgreSQL's direct metadata denial is unchanged. This proof does not establish credential
confinement. Acceptance and remaining activation gates live in [#190](https://github.com/a-novel/infra/issues/190).

### Local measurements

Both published-image variants passed on 27 September 2026, capped at one CPU and 2 GiB RAM with
1 GiB tmpfs. The initial physical cluster was about 23.7 MB; the interruption case adds about
128 MiB of synthetic data. CPU and memory include PostgreSQL, backup workers and the test driver.

| Published input       | Total proof | Restore through SQL | Peak memory (bytes) | CPU time | Retained repository (bytes) |
| --------------------- | ----------- | ------------------- | ------------------- | -------- | --------------------------- |
| JSON Keys v2.6.2      | 13.85 s     | 0.50–1.04 s         | 656,023,552         | 9.10 s   | 7,589,816                   |
| Authentication v2.9.2 | 14.27 s     | 0.48–1.09 s         | 652,488,704         | 9.10 s   | 7,589,501                   |

These are small tmpfs-backed functional measurements, not a throughput benchmark or a production
sizing claim. They do not predict GCS latency, growing WAL volume, SSD load or production RTO.

## Packaging and security review

The published [JSON Keys v2.6.2](https://github.com/a-novel/service-json-keys/blob/v2.6.2/builds/database.Dockerfile)
and [Authentication v2.9.2](https://github.com/a-novel/service-authentication/blob/v2.9.2/builds/database.Dockerfile)
images own PostgreSQL `18.6-1.pgdg13+2` and PGDG pgBackRest `2.59.1-1.pgdg13+1`.
Infra no longer installs or versions a second pgBackRest. It adds only PostgreSQL
`17.11-1.pgdg13+2` from the signed PGDG repository for the negative test.

Both inputs passed `gh attestation verify` on 27 September 2026, requiring their repository's
`release.yaml`, `refs/heads/master`, and GitHub-hosted builders. This verifies their provenance,
not the derived proof image or fitness for a live trial. Retain resolved digests and package
inventories in generated drill evidence; maintained image references remain SemVer tags.

Trivy 0.74.0 scans of both published inputs on 27 September 2026 each report **62 Debian
high/critical findings (one critical)** and **22 inherited gosu findings (one critical)**, using
the advisory database updated on 26 September. Counts are package/advisory pairs, not distinct
exploits. None of the 62 Debian findings has a fixed stable package in that scan; gosu still embeds
Go 1.24.6. The refreshed packaging removes the earlier fixable Perl findings. Remaining advisories
are not automatically reachable vulnerabilities, but neither are they accepted risks:

| Critical finding                                                                   | Reachability assessment and remaining limit                                                                                                                                                                                                                                                                                                                                                                                           |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [libxml2 CVE-2026-6653](https://security-tracker.debian.org/tracker/CVE-2026-6653) | Malformed XML can trigger a use-after-free. Debian still marks trixie vulnerable (minor/no-DSA). pgBackRest's [GCS backend](https://github.com/pgbackrest/pgbackrest/blob/release/2.59.1/src/storage/gcs/storage.c) uses JSON, but PostgreSQL exposes [XML functions](https://www.postgresql.org/docs/18/functions-xml.html); there is no image-wide non-reachability claim. Review SQL access and untrusted XML before a live trial. |
| [gosu CVE-2025-68121](https://pkg.go.dev/vuln/GO-2026-4337)                        | The advisory requires a TLS session-resumption path. [gosu 1.19](https://github.com/tianon/gosu/blob/1.19/main.go) switches user and executes a command, with no TLS handshake evident in that path. This is a source-level inference for this finding, not clearance of every Go advisory. The proof bypasses gosu; production entrypoints can use it.                                                                               |

No advisory ignore or security-gate exception is added. **Live pgBackRest adoption is not approved.**
Before a live trial, refresh the scan and resolve or explicitly review the residual risks with the
operator. The second PostgreSQL major and Go test binary must never enter the live artifact.

To reproduce the advisory inspection with the repository-pinned scanner:

```sh
PROOF_SCAN_DIR="$(mktemp -d)"
podman save --output "${PROOF_SCAN_DIR:?}/image.tar" ghcr.io/a-novel/infra/pgbackrest-proof:local
podman run --rm --cap-drop=all --security-opt=no-new-privileges \
  --mount="type=bind,src=${PROOF_SCAN_DIR:?}/image.tar,dst=/scan/image.tar,ro" \
  docker.io/aquasec/trivy:0.74.0 image --input /scan/image.tar \
  --scanners vuln --severity HIGH,CRITICAL --exit-code=1
```

The scanner needs network access for its public advisory database; the database proof does not.
The archive contains synthetic tooling only. After reviewing the expected nonzero scan result,
remove it with `rm -- "${PROOF_SCAN_DIR:?}/image.tar" && rmdir -- "$PROOF_SCAN_DIR"`.

## Ownership and removal boundary

Baseline at `73b3509`: five logical backup/restore/monitor scripts are 845 lines,
`verify-recovery-points.sh` is 119, and database host startup/shutdown are 563.
This proof removes **zero** production lines; it tests whether a later cutover can remove whole
responsibilities without adding a replacement coordinator.

| Current responsibility                                | Candidate owner                               | What remains ours                                                                   |
| ----------------------------------------------------- | --------------------------------------------- | ----------------------------------------------------------------------------------- |
| Dump/upload handshake, checksums, completion manifest | pgBackRest `backup`, archive and catalog      | Artifact provenance, per-service identity, operation admission and outcome evidence |
| Backup enumeration and physical chain selection       | `info`, explicit backup set / recovery target | Receipt-to-database identity, retained format routing, RPO policy                   |
| Archive verification and expiry                       | `verify`, native dependency-aware `expire`    | Health/age alerting; IAM, storage retention and cost policy                         |
| Restore archive orchestration                         | `restore` and PostgreSQL recovery             | Empty/disposable target checks, exact major/extensions, SQL/application validation  |
| Disk mount, VM startup, secret delivery, readiness    | Existing host owner                           | pgBackRest does not replace these 563 lines                                         |

The [adoption boundary](../pgbackrest-gcs/result-20260927.md#adoption-proposal) maps these responsibilities
to concrete retirement batches and identifies the custody decision still blocking implementation.
Do not port the five scripts to Go in parallel with adopting pgBackRest. If adoption is accepted,
use a small per-service native configuration plus existing operation admission; remove the old
writer path only after the new format passes recovery/custody review. Keep the logical reader,
exact old database images and generation-bound receipts until their last retained backup expires.
Do not reinterpret old `completed.manifest` files as physical backup catalogs.

## Live GCS evidence and adoption decision

The [synthetic storage trial](../gcs-storage/result-20260927.md) and the separately approved
[native JSON Keys trial](../pgbackrest-gcs/result-20260927.md) ran on 27 September 2026.
The latter established full, differential and named-point SQL recovery through GCS, including
exact-set recovery after repairing an aged full-backup dependency with the recovery identity.
The original repository-time cutoff still failed after that repair.

The native trial result owns the remaining acceptance gates, cleanup deadlines and proposed
retirement batches. Neither trial authorizes production custody changes, additional provisioning,
bucket locking or retirement of logical readers. The offline measurements and scans above remain
evidence for their named versions; they do not describe the later CA-corrected image.
