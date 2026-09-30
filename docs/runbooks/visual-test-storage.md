# Studio visual-test storage

The [bootstrap inventory](../../bootstrap/README.md#studio-visual-test-storage) defines the storage and
identity boundaries. This runbook prepares the handoff to the shared Playwright workflow; that workflow
and screenshot comparisons are separate consumer changes. Existing GitHub artifact uploads continue
until the consumer switches storage.

## Provision and hand off

1. Merge the reviewed configuration. An operator follows the
   [protected bootstrap plan/apply](../../ops/README.md#protected-workflow-operations) from `master`,
   checking the management project, region, two new buckets and exact Studio identities. Agents and
   infra PR jobs use mocked validation only. No new API, service-account key or secret payload is needed.
   On an existing management plane, the foundation account's bucket-scoped grants cannot create new
   buckets. A human operator must separately approve and temporarily grant project-level
   `roles/storage.admin` to that apply identity for the reviewed bootstrap operation. Record the grant,
   remove it immediately after the two bucket IAM bindings are applied, and verify root convergence
   using the permanent bucket-scoped grants. Remove it on failure too, then diagnose and review a new
   plan. Never grant Owner or Editor to automation. For initial management-plane creation, the
   [human bootstrap procedure](./bootstrap-management-plane.md#5-establish-temporary-bootstrap-authority)
   already supplies temporary creation authority.
2. Inspect the `studio_visual_tests` output through the approved operator state access. Pass its
   bucket/object paths and `ci` / `master` provider/account pairs as non-secret configuration to Studio's
   shared Playwright action. Keep those values separate from production credentials.
3. Keep the caller at `a-novel/platform-studio/.github/workflows/main.yaml`. Give only the relevant
   storage jobs `id-token: write`. Branch pushes and merge-group jobs use `ci`; baseline publication uses
   `master`, only after successful tests on a master push. Fork PR jobs have no storage identity.
4. Check the existing management-project budget alerts before enabling uploads. Limit archives to
   synthetic test data and remove credentials from traces. Private report links require an authorized
   operator; anonymous access and public website hosting remain disabled.

## Consumer contract

- Upload reports beneath `reports_prefix/<run-id>/<run-attempt>/`, using create-only writes and
  generation precondition `0`. Do not use bucket listing, destination reads or overwrite-based sync
  with the report creator. A retry needs a fresh object name if the previous upload already committed.
- Read metadata for the exact `baseline_object`, then download that immutable generation. Keep its
  generation fixed throughout the run, including retries. Read failures must fail visibly; a missing
  baseline requires explicit first-master seeding and must not silently skip PR comparisons.
- Store the complete comparison batch as one archive at the fixed master object name. Include a
  manifest with the source commit, run ID/attempt, Playwright/browser versions and screenshot settings.
  The archive contains every current baseline image; removing a test removes its image on replacement.
  Reports and traces stay in the expiring reports bucket.
- Serialize master publication, verify the candidate commit still matches current master, and replace
  with an `ifGenerationMatch` precondition using the generation observed before testing (or `0` for
  first seed). A stale run or precondition failure cannot promote. Retry from the current master and
  freshly read baseline. Build and validate the entire archive before uploading; never delete the
  live object before replacement. GCS makes a completed object replacement atomic.
- Only a successful master test batch may publish. A failed, canceled, partial or PR run leaves the
  live baseline untouched. A screenshot change approved on a PR becomes the new baseline only after
  merge and a successful master run; carry the reviewed change authorization into that master run.
- The agreed `allow-screenshot-change` label applies only to visual differences. Comparison must still
  run and retain evidence; functional tests, missing screenshots and upload errors still fail. The
  consumer must validate a human maintainer's label action, refresh checks when the label changes and
  tie the result to the current PR head. Follow infra's
  [deletion-gate pattern](../../.github/workflows/refresh-deletion-gates.yaml) for trusted event handling.
  Label handling does not belong in bucket IAM and is not implemented by this configuration.
- The first master seed needs explicit bootstrap mode and complete functional tests. Browser/platform
  upgrades that change rendering require the same reviewed baseline update procedure.

References: [Playwright comparisons](https://playwright.dev/docs/test-snapshots),
[GCS consistency and atomicity](https://docs.cloud.google.com/storage/docs/consistency),
[generation preconditions](https://docs.cloud.google.com/storage/docs/request-preconditions).

## Verify after apply

Use approved operator access to inspect the buckets and their effective IAM, including inherited
project grants. The providers and accounts must match the `studio_visual_tests` output.

| Check                             | Expected result                                                                                                                                                                               |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Both buckets                      | Regional Standard, uniform access, public access prevention, soft delete disabled; no bucket-wide retention lock.                                                                             |
| Reports policy                    | Versioning disabled; delete when object age reaches seven days.                                                                                                                               |
| Baseline policy                   | Versioning enabled; delete only noncurrent generations seven days after replacement. No live-object age rule.                                                                                 |
| CI identity                       | Read the exact baseline generation and create a fresh run report. Baseline writes/deletes, report reads/overwrites/deletes, bucket listing, unrelated prefixes, state and secrets are denied. |
| Publisher identity                | Replace the exact master archive with a generation precondition. Other objects and bucket-policy changes are denied.                                                                          |
| Federation                        | CI works on Studio branch push/merge-group runs. Publisher works only on Studio master pushes. Other repositories/workflows, tags, PR events and branch publication are denied.               |
| Failed or overlapping publication | A failed upload preserves the old live archive; a stale generation precondition rejects replacement.                                                                                          |
| Quiet master                      | The same live generation remains readable after seven days without a successful master run. Superseded generations become eligible for cleanup after seven days.                              |

Cloud lifecycle deletion is asynchronous; seven days is eligibility, not an exact removal deadline.
Run non-destructive identity checks before enabling publication. Exercise replacement/recovery with
an explicitly approved initial test baseline. Never delete the active baseline as a permissions probe.
The repository's mocked tests verify policy structure; these live checks verify the deployed boundary.

## Recovery and retirement

For an incomplete upload, retry without deleting the live object. For a bad successful publication,
an operator can copy a known-good noncurrent generation back to the fixed object name, guarded by the
current generation precondition. Validate its manifest and record which master commit it represents;
then rerun current-master tests. Noncurrent generations are recoverable only until lifecycle deletes
them. If the live archive was explicitly deleted, it becomes noncurrent and has that same recovery
window. `prevent_destroy` protects infrastructure changes, not object operations.

Reports and expired historical baselines have no soft-delete recovery. If no valid master generation
remains, reseed explicitly from reviewed master. To retire the feature, first disable the consumer and
federation, export any retained evidence, then review removal of deletion protection and bucket contents.
Changing the bucket location requires a separately reviewed migration.

## Cost estimate

Assume **2–4 GiB per report batch**, a 30-day month and steady daily volume. For the default Belgium
region, Standard storage is approximately **$0.020/GiB-month**. Upload traffic is free. Internet
downloads to GitHub-hosted runners in Europe or North America start at **$0.12/GiB**, then $0.11 after
1,024 GiB/month. Rates verified against Google's [storage pricing](https://cloud.google.com/storage/pricing)
and [pricing examples](https://cloud.google.com/storage/pricing-examples) on September 30, 2026.

| Runs/day | Temporary reports retained (7 days) | Report storage/month | Downloads/month if every run fetches a 2–4 GiB baseline |
| -------- | ----------------------------------- | -------------------- | ------------------------------------------------------- |
| 1        | 14–28 GiB                           | $0.28–$0.56          | $7.20–$14.40                                            |
| 10       | 140–280 GiB                         | $2.80–$5.60          | $72.00–$142.24                                          |
| 50       | 700–1,400 GiB                       | $14.00–$28.00        | $340.24–$670.24                                         |

A live 2–4 GiB master archive adds **$0.04–$0.08/month** indefinitely. Superseded baseline history adds
approximately `master publications/day × 7 × baseline GiB × $0.020` per month. At one master
publication/day with 2–4 GiB archives, that is another **$0.28–$0.56/month**. If every run publishes
master, historical baseline storage is approximately another report-storage column.

This treats the comparison archive as large as the full report for the download estimate. Keeping
traces and HTML reports outside the archive usually reduces comparison downloads; measure actual
baseline bytes before setting the budget. Human report downloads add egress too. Reusing a cached
immutable generation avoids repeat downloads without accepting a stale baseline.

Regional Standard requests cost $0.005 per 1,000 Class A operations and $0.0004 per 1,000 Class B
operations; a few archives per run keep these small. Estimates exclude taxes, audit-log charges,
other project usage, credits and lifecycle cleanup delays. Soft delete is explicitly disabled on
both buckets, so expired objects do not incur an additional soft-delete retention period.
