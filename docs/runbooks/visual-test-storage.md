# Studio visual-test storage

Studio visual evidence uses two dedicated Google Workspace Shared Drives. Bootstrap owns the Drive
API and GitHub federation described in the [resource inventory](../../bootstrap/README.md#studio-visual-test-storage).
The shared workflow owns comparison, publication and cleanup. This runbook prepares its activation;
merging infrastructure configuration alone does not change Studio's existing artifact uploads.

## Provision and hand off

1. Merge the reviewed bootstrap configuration. An operator follows the
   [protected bootstrap plan/apply](../../ops/README.md#protected-workflow-operations) from `master`.
   Review the Drive API, two service accounts and two providers. Agents and PR checks use mocked
   validation only. The existing service-usage and IAM administration grants cover these resources.
2. Read `studio_visual_tests` through approved operator state access. Confirm that `ci` names
   `studio-visual-ci` and `maintenance` names `studio-visual-maintenance` in the management project.
3. A Workspace administrator creates **Studio visual references** and **Studio visual results** as
   dedicated Shared Drives. Record each Drive ID from its URL. Service accounts cannot own files in
   My Drive and do not inherit domain membership. Confirm the Workspace edition supports Shared Drives
   and that external-member policy permits the two service accounts before activation.
4. Add the exact service-account email addresses with the membership below. Keep both Drives private,
   restrict file access to Drive members (`driveMembersOnly`), and restrict folder sharing to managers.
   Domain-only membership must allow these specific external service accounts. Retain named human
   managers for recovery. Do not grant either account access to general company Drives.
5. Set the following non-secret Studio repository variables from the verified output and Drive URLs.
   The consumer must explicitly request OAuth scope `https://www.googleapis.com/auth/drive` through
   service-account impersonation. No credential file or domain-wide delegation is needed.
6. Release and adopt the shared workflow, run the allow/deny and large-transfer checks below, then seed
   from reviewed master using its explicit initial-seed control. Disable seed mode after the first
   successful publication. Missing references fail ordinary comparisons.

| Shared Drive | CI role                | Maintenance role      |
| ------------ | ---------------------- | --------------------- |
| References   | Viewer (`reader`)      | Manager (`organizer`) |
| Results      | Contributor (`writer`) | Manager (`organizer`) |

Drive requires Manager authority on the parent to permanently delete a Shared Drive file. Maintenance
therefore holds this authority only on the two dedicated Drives. Contributors can modify result files;
GitHub run metadata and the trusted workflow decide eligibility for publication.

| Repository variable                  | Source                                                         |
| ------------------------------------ | -------------------------------------------------------------- |
| `STUDIO_VISUAL_CI_PROVIDER`          | `studio_visual_tests.identities.ci.identity_provider`          |
| `STUDIO_VISUAL_CI_ACCOUNT`           | `studio_visual_tests.identities.ci.service_account`            |
| `STUDIO_VISUAL_MAINTENANCE_PROVIDER` | `studio_visual_tests.identities.maintenance.identity_provider` |
| `STUDIO_VISUAL_MAINTENANCE_ACCOUNT`  | `studio_visual_tests.identities.maintenance.service_account`   |
| `STUDIO_VISUAL_REFERENCES_DRIVE`     | References Shared Drive ID                                     |
| `STUDIO_VISUAL_RESULTS_DRIVE`        | Results Shared Drive ID                                        |

The consumer workflows are `main.yaml` and trusted `visual-tests.yaml`. Give only the relevant jobs
`id-token: write`. Maintenance accepts only events evaluated on `refs/heads/master`; it must never
check out or execute PR code. Fork runs have no candidate identity. Synthetic test data is the only
permitted content; traces can contain cookies and credentials, so access stays private.

## Consumer contract

- A **reference batch** contains the latest successful master screenshots. A **branch batch** holds
  the latest completed run's screenshots, traces, report and service logs. Keep the reference regardless
  of age, including after months without a run. Keep one latest published batch per live branch.
- Use Drive file IDs and bounded metadata, not names as unique keys. Upload immutable archives with
  resumable transfers and retries; stream 2–4 GiB batches with bounded memory. Validate complete uploads
  before making them current. Readers verify checksums and retry selection if a replacement removed
  the old file during download.
- Store each batch as a fresh file, then permanently delete superseded files after publication.
  Updating binary content can retain old revisions, and Trash retains deleted data. Neither behavior
  meets the one-batch retention policy. Brief overlap during a replacement is necessary.
- Serialize trusted publication and cleanup. Verify GitHub's run identity, attempt, branch, current
  head and test result. A stale, failed, canceled, partial or branch run cannot replace references.
  Candidate jobs upload pending evidence; completion events reconcile branch retention. Master publishes its locally validated batch directly with the maintenance identity. Cleanup never promotes candidate-uploaded files into references.
- Remove batches after PR merge or branch deletion. Recheck live GitHub state before publication so
  an in-flight upload cannot revive a removed branch. A scheduled sweep removes orphaned uploads and
  retries interrupted cleanup. API or permission failures are visible and never treated as empty lists.
- Native Playwright comparison always runs. The human-maintainer `allow-screenshot-change` label
  permits visual differences for the exact reviewed PR head. Functional failures, incomplete captures,
  missing references and upload errors remain failures. Refresh checks on label changes and carry the
  reviewed approval into the successful post-merge master run. Follow infra's
  [trusted event pattern](../../.github/workflows/refresh-deletion-gates.yaml).
- Explicit first-master seeding requires a complete successful functional run. Rendering changes from
  browser/platform upgrades use the same reviewed update path. No screenshot/report GitHub artifact
  upload remains on the Drive path; small coverage artifacts can remain for Codecov.

## Verify after apply

Inspect the providers, effective Google Cloud IAM and Workspace membership independently. HCL output
alone does not prove Drive access. Use an approved disposable test batch for destructive probes.

| Check                      | Expected result                                                                                                                                |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| CI federation              | Studio `main.yaml` branch pushes and merge groups authenticate; other repositories, workflows, tags and PR events fail.                        |
| Maintenance federation     | Only master `main.yaml` pushes and master `visual-tests.yaml` allowlisted events authenticate. Candidate branch and other event attempts fail. |
| CI Drive access            | Read references and upload results. Reference writes/deletes, permanent result deletion, unrelated Drives, state and secrets fail.             |
| Sharing                    | Anonymous and nonmember requests fail; service-account access succeeds without user impersonation.                                             |
| Maintenance access         | Publish and permanently delete disposable evidence in the dedicated Drives. No project-wide infrastructure or company Drive access.            |
| Large/interrupted transfer | Upload and download a 4 GiB test archive; checksums match, memory stays bounded, and a resumed upload produces one complete file.              |
| Failed/stale publication   | Current references remain readable; old runs cannot replace newer master results.                                                              |
| Cleanup race               | Merge/delete while a branch run is uploading; after reconciliation no branch batch remains. A missed event is repaired by the sweep.           |
| Quiet master               | The same reference stays readable past seven days without a successful replacement.                                                            |

Complete these checks before enabling normal uploads. If Workspace blocks service-account membership,
stop activation and review that policy; do not introduce account keys or domain-wide delegation as a
fallback. Google documents [roles](https://developers.google.com/workspace/drive/api/guides/ref-roles),
[Shared Drive support](https://developers.google.com/workspace/drive/api/guides/enable-shareddrives),
[resumable uploads](https://developers.google.com/workspace/drive/api/guides/manage-uploads),
[revisions](https://developers.google.com/workspace/drive/api/guides/manage-revisions) and
[permanent deletion](https://developers.google.com/workspace/drive/api/guides/delete).

## Recovery and retirement

Retry an incomplete upload while keeping the current reference. Permanent cleanup has no Drive Trash
recovery; the latest-only policy intentionally provides no historical reference archive. If a reference
is lost or a bad publication is confirmed, pause publication, review the source commit and explicitly
reseed from trusted master. Never select a branch batch as an automatic recovery source.

To retire the feature, disable the consumer and revoke Drive membership, preserve any evidence a human
needs, then review identity removal. Shared Drives remain Workspace-owned and are not destroyed by
OpenTofu. No visual-test GCS resources were applied as part of this proposal; if an operator provisioned
an earlier revision independently, inventory it and plan its retirement separately.

## Capacity and cost

Within the existing Workspace pooled-storage allowance, this design needs no additional storage
subscription. At **2–4 GiB per batch**, master plus ten branch batches occupies about **22–44 GiB**, plus
short-lived upload overlap and orphaned files until cleanup succeeds. Fifty runs per day transferring
one batch each way use roughly **100–200 GiB/day in each direction**.

Google currently lists a free standard allowance, with **400 million quota units/day/project** and
**1 TB/day/project of downloads** as future billing thresholds. An account can upload/copy **750 GB/day**.
API methods consume different numbers of quota units; archive transfers reduce request count. Shared
Drive storage headroom, API usage and cleanup failures still require monitoring.

Google has announced future charges above daily thresholds with at least 90 days' notice; published
rates and activation dates must be rechecked before rollout. Sources, checked September 30, 2026:
[Drive limits](https://developers.google.com/workspace/drive/api/guides/limits) and
[Workspace API policy](https://developers.google.com/workspace/tools-safety).
