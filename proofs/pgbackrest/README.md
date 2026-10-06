# Disposable pgBackRest proof

Evaluation for [the backup-owner comparison](https://github.com/a-novel/infra/issues/190),
not a production backup implementation. The Go file is a test-only driver for native commands;
it is not linked into `infra`. The image uses each service's published PostgreSQL and pgBackRest,
adding only the test driver. No cloud resources,
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

Keep this image restricted to the synthetic, offline test, regardless of its scan result.
Do not pass credentials, mount real data, enable networking, or use it as a deployment artifact.

## What the test establishes

| Scenario               | Native behavior checked                                                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Full backup            | Restore into a clean directory; verify the row, role, and a real `uuid-ossp` function call through SQL.                                           |
| Point-in-time recovery | Restore a named point after a committed write; exclude the subsequent write. Wait for recovery to finish, not merely for read-only SQL readiness. |
| Interrupted copy       | Stop pgBackRest after backup data starts copying. Its catalog must remain unchanged and the earlier full backup must still restore.               |
| Missing/corrupt WAL    | Removing or corrupting a required archived segment makes `archive-get` fail and prevents the restored server from becoming ready.                 |
| Incompatible major     | The published server refuses an incompatible `PG_VERSION` marker in a disposable restored directory with its native incompatibility error.        |
| Retention              | Retain two full backups and a dependent differential. Restore the differential and newest full; the expired full is no longer selectable.         |
| Repository integrity   | Require a healthy native `verify` report over the retained repository.                                                                            |

The cases intentionally share one evolving repository and stop on the first failure. This is not a
coverage suite for pgBackRest internals. Its output includes native catalog sizes, repository bytes,
restore-through-SQL duration and cgroup resource counters when available.

The retention case first checks that native `expire --dry-run` leaves repository content unchanged.
It then denies manifest removal and, separately, data cleanup after the catalog has changed.
Both failed commands must leave the retained full/differential sets restorable through SQL.
Restoring fixture permissions permits an explicit native reconciliation; no catalog is repaired by
the test. These POSIX denials establish expiry ordering, not GCS retention behavior. A dry run does
not reserve the repository or prove later deletion will succeed. The
[live acceptance procedure](../../docs/runbooks/backup-and-restore-postgresql.md#native-expiry-acceptance)
covers the separate GCS generation lifecycle.

Interruption uses `pgbackrest --force stop` followed by `start`, not a bespoke process coordinator.
An exploratory parent-only SIGTERM left a worker holding the backup lock. A future VM/container
integration must test its actual shutdown path; parent exit is not evidence that all work stopped.

This is POSIX storage evidence, **not** proof of interrupted GCS uploads, GCS permissions, locked
retention, generation selection, host-loss recovery, or the production 6-hour RPO / 90-minute RTO.
The proof runs each image's extension initialization SQL; the published runtime is unchanged.
The wrong-major fixture exercises PostgreSQL's native startup version guard, not real PostgreSQL 17
data or cross-major conversion. It does not exercise the original entrypoints, application
migrations, historical images, or native backup integration on the actual COS host.

### Offline SQL verification

`TestOfflineSQL` exercises both services through the same recovery worker with full/differential `archive-copy` backups,
then starts PostgreSQL with no archive reader or network. It requires the expected system ID and native
paused-at-consistency state, checks tables/roles/extensions, and stops the server before completion.
It captures the application fingerprint independently before each backup and exercises the worker's
comparison, including wrong-set, missing-row and empty expectations. A compact source table checks
UUID ordering, session formatting and nullable-field distinctions. Authentication also includes both
credential and short-code rows, including binary payloads; sensitive values stay inside SQL.
Requests without an expectation retain schema-only behavior, not data-fidelity evidence.
Restored configuration containing an unavailable preload library is ignored. Missing copied WAL and
failed SQL checks leave no success marker; used attempts refuse replay. The proof logs copied WAL's
stored and restored sizes; synthetic compression is not a production cost estimate. Host-network
enforcement and real cloud custody still need the separately approved activation drill.

### Native repository transport

`TestRepositoryTLS` reuses the recovery driver with a native repository server and temporary test
certificates on container loopback. Both service-image variants check backup/WAL transfer and SQL
recovery; a CA-signed but unauthorized client, wrong stanza and untrusted server must fail, with
authorized positive controls. A stopped server prevents restore, and an explicit retry of the same
set succeeds after restart. No external network, credential proxy or new runtime dependency is used.
Integrity cases read the native text report for healthy, missing and corrupt backup bundles, with
repaired positive controls. pgBackRest can exit zero when the report says `status: error`; an empty
repository can also exit zero. These cases protect the
[prepared verification worker's](../../environments/service-foundation/README.md#native-integrity-check)
report-based alert contract. They do not emulate Cloud Logging or establish live delivery.
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

The published [JSON Keys v2.6.5](https://github.com/a-novel/service-json-keys/blob/v2.6.5/builds/database.Dockerfile)
and [Authentication v2.9.5](https://github.com/a-novel/service-authentication/blob/v2.9.5/builds/database.Dockerfile)
images own Wolfi PostgreSQL 18.6 and pgBackRest 2.59.1. Infra neither rebuilds nor installs database
packages. The proof adds a Go test driver to each published image, leaving its tools and shared
libraries intact. The negative-major fixture relies on PostgreSQL's
[native version guard](https://github.com/postgres/postgres/blob/REL_18_STABLE/src/backend/utils/init/miscinit.c),
so it needs no second server, package builder or dependency-update rules.

Both inputs passed `gh attestation verify` on 30 September 2026, requiring their repository's
`release.yaml`, `refs/heads/master`, and GitHub-hosted builders. This verifies their provenance,
not the derived proof image or fitness for a live trial. Retain resolved digests and package
inventories in generated drill evidence; maintained image references remain SemVer tags.

Trivy 0.74.0 scans of both published inputs on 30 September 2026 report **zero HIGH/CRITICAL
findings and zero secret findings**, without ignores or policy exceptions. This replaces the earlier
Debian inputs, whose unchanged scan blocked adoption; it is not a claim of no vulnerabilities.
The derived recovery image is scanned separately by CI. **Live pgBackRest adoption remains unapproved.**
Refresh scans before activation. The test driver never enters the recovery image.

Wolfi is a fresh-database boundary, not an in-place Debian data-directory upgrade. Retain old images
and the logical reader for existing backups until their retention ends; neither this proof nor a
successful physical restore authorizes a live reset, old-data conversion or cutover.

To reproduce the advisory inspection with the repository-pinned scanner:

```sh
PROOF_SCAN_DIR="$(mktemp -d)"
podman save --output "${PROOF_SCAN_DIR:?}/image.tar" ghcr.io/a-novel/infra/pgbackrest-proof:local
podman run --rm --cap-drop=all --security-opt=no-new-privileges \
  --mount="type=bind,src=${PROOF_SCAN_DIR:?}/image.tar,dst=/scan/image.tar,ro" \
  docker.io/aquasec/trivy:0.74.0 image --input /scan/image.tar \
  --scanners vuln,secret --severity HIGH,CRITICAL --exit-code=1
```

The scanner needs network access for its public advisory database; the database proof does not.
The archive contains synthetic tooling only. After reviewing the scan result,
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
bucket locking or retirement of logical readers. Historical measurements and live trials apply only
to their named versions; the Wolfi image refresh has not undergone a live cloud recovery trial.
