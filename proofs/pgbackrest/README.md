# Disposable pgBackRest proof

Evaluation for [the backup-owner comparison](https://github.com/a-novel/infra/issues/190),
not a production backup implementation. The Go file is a test-only driver for native commands;
it is not linked into `infra`. No cloud resources, credentials, existing databases, production
images, schedules, or retention policies are used or changed.

## Run locally

From the repository root:

```sh
a-novel build --type=podman -y
podman run --rm --network=none --read-only --cap-drop=all \
  --security-opt=no-new-privileges --cpus=1 --memory=2g --pids-limit=128 \
  --tmpfs=/tmp:rw,size=1g,mode=1777 --timeout=660 \
  ghcr.io/a-novel/infra/pgbackrest-proof:local
```

The local tag is built, never pushed. All data lives in container tmpfs and disappears on exit.
There are no host mounts or published ports. The process runs as `postgres`, using peer-authenticated
Unix sockets; host authentication is SCRAM, not trust. Normal Go tests skip this package unless
`INFRA_PGBACKREST_PROOF=1`; the proof image sets it and CI runs that image offline.

The image has advisory findings below. Keep it restricted to this synthetic, offline test.
Do not pass credentials, mount real data, enable networking, or use it as a deployment artifact.

## What the test establishes

| Scenario               | Native behavior checked                                                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Full backup            | Restore into a clean directory; verify the row, role, and `uuid-ossp` extension through SQL.                                                      |
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
It also does not prove compatibility with our Alpine-based database artifacts or their extensions.
Those require the packaging and cloud steps below before adoption.

### Local measurements

On 26 September 2026, the rebuilt image passed in **15.52 seconds**, capped at one CPU and 2 GiB
RAM with 1 GiB tmpfs. Restores through SQL verification took **0.59–1.21 seconds**;
the initial physical cluster was about 23.7 MB. The temporary interruption case adds about
128 MiB of synthetic data. After native expiry, the repository (including WAL and catalog)
contained **7,589,588 apparent bytes**. Container peak memory was **653,733,888 bytes** and CPU
time about **10.34 seconds**, including PostgreSQL, backup workers and the test driver.
The test image was about **547 MB** unpacked, including both PostgreSQL majors.

These are small tmpfs-backed functional measurements, not a throughput benchmark or a production
sizing claim. They do not predict GCS latency, growing WAL volume, SSD load or production RTO.

## Packaging and security review

The Dockerfile selects Docker Official Images by version tag and installs exact PGDG package versions:
pgBackRest `2.59.1-1.pgdg13+1`, PostgreSQL 18.6, and PostgreSQL 17.11 solely for the negative test.
APT verifies the signed repository metadata and package hashes. The PGDG key in the inspected base has
fingerprint `B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8`, matching the
[PostgreSQL package repository](https://wiki.postgresql.org/wiki/Apt).
The [upstream pgBackRest project](https://github.com/pgbackrest/pgbackrest) is MIT-licensed and
actively maintained; its [guide](https://pgbackrest.org/user-guide.html#installation) recommends
distribution packages. This avoids maintaining a C build/distribution pipeline for the proof.

These checks establish the public distribution source and integrity, not our own production
attestation. Image tags and transitive Debian package versions can change between builds; retain the resulting
image digest and package inventory with any future drill evidence.

Trivy 0.74.0 on 26 September 2026 reported **62 Debian high/critical package findings** (including
one critical) and **22 findings in the inherited `gosu` binary**. The Go proof binary had none.
Counts are package/advisory pairs, not distinct exploitable vulnerabilities:

- Debian `libxml2` `2.12.7+dfsg+really2.9.14-2.1+deb13u3` was flagged for
  [CVE-2026-6653](https://security-tracker.debian.org/tracker/CVE-2026-6653).
  Debian lists trixie as vulnerable but classifies the issue as minor/no-DSA; the scanner classifies
  it as critical. There was no fixed trixie version in the scan. Do not equate severity with a
  proven reachable exploit, or silently discard the finding.
- Inherited `gosu` was built with Go 1.24.6, including
  [CVE-2025-68121](https://pkg.go.dev/vuln/GO-2026-4337). The proof does not call `gosu` or the
  original image entrypoint. Production packaging should omit unused tooling and use supported,
  patched dependencies rather than inherit this test image.

No advisory ignore or security-gate exception is added. **Production packaging is not approved.**
Before a live trial, review reachable findings, build a minimal patched artifact compatible with
the selected database image, verify its provenance, scan it, and obtain human approval. The second
PostgreSQL major and the Go test binary belong only to this proof, never to that artifact.

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

Do not port the five scripts to Go in parallel with adopting pgBackRest. If adoption is accepted,
use a small per-service native configuration plus existing operation admission; remove the old
writer path only after the new format passes recovery/custody review. Keep the logical reader,
exact old database images and generation-bound receipts until their last retained backup expires.
Do not reinterpret old `completed.manifest` files as physical backup catalogs.

## Human-only GCS contract drill — not yet authorized to run

Local success is insufficient to replace create-only custody. This next drill requires a separately
approved, patched artifact, a disposable private PostgreSQL 18 host with synthetic data, and a **new
per-service management-project bucket**. It must not reuse the production backup bucket.
Do not provision these or change IAM/retention as part of this proof.

The reviewed setup must specify the bucket, runtime identity and cleanup owner; versioning;
the minimum retention period; native full/WAL retention; and recovery access after workload-project
loss. The existing create-only backup principal cannot be reused unchanged: the native catalog is
mutable. Test the proposed bucket-scoped `storage.objects.create/get/list/delete` permissions,
not an unreviewed project-wide storage-admin grant. Do not grant runtime bucket-policy mutation.
Google documents the important interaction between
[versioning](https://docs.cloud.google.com/storage/docs/object-versioning) and
[retention locks](https://docs.cloud.google.com/storage/docs/bucket-lock): retaining generations
does not by itself prevent the current catalog from being replaced. Locking retention is irreversible.

After that setup is approved, a human can inspect the exact boundary:

```sh
(
set -euo pipefail
gcloud storage buckets describe "gs://${INFRA_BACKUP_DRILL_BUCKET:?}" \
  --project="${INFRA_MANAGEMENT_PROJECT_ID:?}" \
  --format='yaml(name,versioning,retention_policy,lifecycle_config,soft_delete_policy)'
gcloud storage buckets get-iam-policy "gs://${INFRA_BACKUP_DRILL_BUCKET:?}" \
  --project="${INFRA_MANAGEMENT_PROJECT_ID:?}" --format=json
)
```

On that disposable host, the reviewed pgBackRest configuration must use stanza `proof`, the new
bucket, `repo1-type=gcs`, `repo1-gcs-key-type=auto`, a synthetic `pg1-path`, and no static key.
Run as its dedicated database user, with no other stanza in the configuration:

```sh
(
set -euo pipefail
pgbackrest --config="${INFRA_BACKUP_DRILL_CONFIG:?}" --stanza=proof stanza-create
pgbackrest --config="${INFRA_BACKUP_DRILL_CONFIG:?}" --stanza=proof check
pgbackrest --config="${INFRA_BACKUP_DRILL_CONFIG:?}" --stanza=proof --type=full backup
pgbackrest --config="${INFRA_BACKUP_DRILL_CONFIG:?}" --stanza=proof --output=json info
gcloud storage objects list "gs://${INFRA_BACKUP_DRILL_BUCKET:?}/**" \
  --project="${INFRA_MANAGEMENT_PROJECT_ID:?}" --all-versions \
  --format='table(name,generation,size,retentionExpirationTime)'
)
```

Then execute and record this acceptance matrix using the approved identities and repository:

| Test                                                         | Required evidence before adoption                                                                                                                                                                            |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Backup followed by another backup                            | Catalog advances; prior generations remain readable with the recovery identity.                                                                                                                              |
| Interrupted upload (`pgbackrest --force stop`, then `start`) | No partial backup is selectable; previous exact recovery point restores. Test forced host/container loss as well as native cancellation.                                                                     |
| Native expiry while an object is retention-protected         | Protected generations cannot be deleted. Record whether backup/expiry returns failure after catalog advancement; do not blindly replay it.                                                                   |
| Missing/corrupt current catalog or WAL                       | Recovery identity restores the selected historical catalog and matching WAL generations using the pinned repository target time; SQL verification passes. Never mutate the real repository to simulate this. |
| Cross-service access and policy changes                      | The writer cannot access a peer bucket or change its own retention/IAM policy.                                                                                                                               |
| Workload identity removed                                    | Management-side recovery identity can still select and restore the exact retained backup.                                                                                                                    |

Use native `info`, `verify`, explicit `--set`, `--repo-target-time` and `restore`; do not build a
second catalog or generic object-age sweeper. Exact mutation commands and identity grants belong in
the separately reviewed live-drill change once those coordinates and policies are chosen.
Until this matrix and packaging pass, the outcome is **promising local behavior, no live cutover**.
