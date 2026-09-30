# Platform visual-test storage

Platform visual evidence uses one dedicated **Platform visual tests** Google Workspace Shared Drive.
Each platform owns a folder with separate `references` and `results` children. Bootstrap owns the
Drive API and GitHub federation described in the [resource inventory](../../bootstrap/README.md#platform-visual-test-storage).
Shared workflows own comparison, publication and cleanup; platforms supply identity and folder IDs.
Merging infrastructure configuration alone does not change existing artifact uploads.

## Identities and subscriptions

These service accounts are Google Cloud workload identities, not Workspace user accounts. They need
no paid Workspace seat. Files uploaded into a Shared Drive belong to the organisation and consume its
existing pooled storage. They cannot own files in My Drive and are not members of the Workspace domain,
so a Workspace administrator must allow and explicitly grant their access. See Google's
[Shared Drive storage model](https://developers.google.com/workspace/drive/api/guides/about-shareddrives),
[service-account sharing rules](https://developers.google.com/workspace/drive/api/guides/manage-shareddrives)
and [IAM pricing](https://cloud.google.com/iam/pricing).

GitHub exchanges its job identity for a short-lived Drive access token. No shared secret,
service-account key, subscribed automation user or domain-wide delegation is needed. Folder IDs and
provider/account coordinates are non-secret repository variables.

## Provision and hand off

1. Merge the reviewed bootstrap configuration. An operator follows the
   [protected bootstrap plan/apply](../../ops/README.md#protected-workflow-operations) from `master`.
   Review the Drive API and two accounts/providers per configured platform. Agents and PR checks use
   mocked validation only. Existing service-usage and IAM administration grants cover these resources.
2. Read `visual_tests` through approved operator state access. For Studio, use
   `visual_tests.platforms.studio`; the accounts remain `studio-visual-ci` and
   `studio-visual-maintenance` in the management project.
3. A Workspace administrator creates the dedicated **Platform visual tests** Shared Drive once, with
   named human Managers for recovery. Keep ordinary company documents outside it. Create the paths
   exported under each platform's `folders`: currently `platform-studio/references` and
   `platform-studio/results`. Record the two child folder IDs from their URLs, not the Drive ID.
4. Grant access using the table below. CI must have no Drive-level or platform-parent membership;
   share only its two child folders. Allow explicit nonmember folder sharing (`driveMembersOnly=false`)
   and the service accounts under external-sharing policy; restrict folder sharing to Managers.
   Do not enable public, link-wide or domain-wide access. Maintenance is a Manager of the dedicated
   test Drive, so its authority spans all platform folders. The trusted action additionally scopes
   every list, upload and cleanup to its configured folder IDs and GitHub repository.
5. Set the same six non-secret `VISUAL_*` variables in each platform repository using its own output
   and folder IDs. Request OAuth scope `https://www.googleapis.com/auth/drive` through service-account
   impersonation. No credential file is needed.
6. Release and adopt the shared workflow, run the allow/deny and large-transfer checks below, then seed
   from reviewed master by setting `VISUAL_SEED_SHA` to that exact commit and rerunning its main run.
   Unset it after the first successful publication. Missing references fail ordinary comparisons.

| Resource                     | CI access                                   | Maintenance access                                                        |
| ---------------------------- | ------------------------------------------- | ------------------------------------------------------------------------- |
| Dedicated test Drive         | No membership                               | Manager (`organizer`)                                                     |
| `platform-studio/references` | Viewer (`reader`), direct folder grant      | Inherited Manager                                                         |
| `platform-studio/results`    | Contributor (`writer`), direct folder grant | Inherited Manager                                                         |
| Another platform's folders   | No access                                   | Inherited Manager; trusted action operates only on its configured folders |

Google requires Manager authority on a parent for permanent deletion. Keeping maintenance at the
Drive level supports that operation without depending on folder-only Manager grants. Candidate CI
cannot replace reference files or permanently delete results. The action rejects My Drive, root
folders, mismatched platform parents and a candidate identity with reference write authority.

| Repository variable           | Source within `visual_tests.platforms.<platform>`              |
| ----------------------------- | -------------------------------------------------------------- |
| `VISUAL_CI_PROVIDER`          | `identities.ci.identity_provider`                              |
| `VISUAL_CI_ACCOUNT`           | `identities.ci.service_account`                                |
| `VISUAL_MAINTENANCE_PROVIDER` | `identities.maintenance.identity_provider`                     |
| `VISUAL_MAINTENANCE_ACCOUNT`  | `identities.maintenance.service_account`                       |
| `VISUAL_REFERENCES_FOLDER`    | ID of this platform's `references` child folder                |
| `VISUAL_RESULTS_FOLDER`       | ID of this platform's `results` child folder                   |
| `VISUAL_SEED_SHA`             | Exact reviewed master SHA; temporary first-reference seed only |

The consumer workflows are `main.yaml` and trusted `visual-tests.yaml`. Give only the relevant jobs
`id-token: write`. Maintenance accepts only events evaluated on `refs/heads/master`; it must never
check out or execute PR code. Fork runs have no candidate identity. Synthetic test data is the only
permitted content; traces can contain cookies and credentials, so access stays private.

## Add another platform

Add one entry to `visual_test_platforms` with its short slug, full `a-novel/platform-*` repository name
and verified numeric repository ID (`gh api repos/OWNER/REPO --jq .id`). Bootstrap generates both
accounts, both federation providers and their bindings from that entry. Keep Studio in the map when
supplying an override. No back-office identity is provisioned until its repository exists.

After applying that reviewed change, create the exported folder pair in the existing test Drive and
grant the same roles above. Set the same variable names in the new repository; reuse the shared
Playwright actions and Studio's thin caller conventions without copying upload or retention code.
Seed its own reviewed master. Each platform compares, retains and cleans up its own batches; adding
one requires no change to shared action code or existing platform configuration.

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
  Candidate jobs upload pending evidence; completion events reconcile branch retention. Master stages
  its locally validated batch directly in the references folder with the maintenance identity. Serialized
  maintenance verifies the completed successful `test-browser` job and current master before marking
  that batch current. It never copies candidate-uploaded results into references. After publication,
  delete the duplicate master results batch; keep failed master diagnostics until a successful replacement.
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

| Check                      | Expected result                                                                                                                                                                                                                              |
| -------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CI federation              | Each platform `main.yaml` branch push/merge group authenticates only as its own identity; other repositories, workflows, tags and PR events fail.                                                                                            |
| Maintenance federation     | Only master `main.yaml` pushes and master `visual-tests.yaml` allowlisted events authenticate. Candidate branch and other event attempts fail.                                                                                               |
| CI Drive access            | Read own references and upload own results. Reference writes/deletes, permanent deletion, other platforms, unrelated Drives, state and secrets fail.                                                                                         |
| Sharing                    | Anonymous and ungranted requests fail; explicitly shared folder access succeeds without Drive membership or user impersonation.                                                                                                              |
| Maintenance access         | Publish and permanently delete disposable evidence in the dedicated test Drive. Manager authority spans the dedicated test Drive, while cleanup leaves another platform's batches intact. No general company Drive or infrastructure access. |
| Large/interrupted transfer | Upload and download a 4 GiB test archive; checksums match, memory stays bounded, and a resumed upload produces one complete file.                                                                                                            |
| Failed/stale publication   | Current references remain readable; old runs cannot replace newer master results.                                                                                                                                                            |
| Cleanup race               | Merge/delete while a branch run is uploading; after reconciliation no branch batch remains. A missed event is repaired by the sweep.                                                                                                         |
| Quiet master               | The same reference stays readable past seven days without a successful replacement.                                                                                                                                                          |

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
needs, then review identity removal. The Shared Drive remains Workspace-owned and are not destroyed by
OpenTofu. No visual-test GCS resources were applied as part of this proposal; if an operator provisioned
an earlier revision independently, inventory it and plan its retirement separately.

## Capacity and cost

Within the existing Workspace pooled-storage allowance, this design needs no additional storage
subscription. At **2–4 GiB per batch**, one platform's master plus ten branch batches occupies about **22–44 GiB**, plus
short-lived upload overlap and orphaned files until cleanup succeeds. Sum this capacity across platforms. Fifty runs per day transferring
one batch each way use roughly **100–200 GiB/day in each direction**.

Google currently lists a free standard allowance, with **400 million quota units/day/project** and
**1 TB/day/project of downloads** as future billing thresholds. An account can upload/copy **750 GB/day**.
API methods consume different numbers of quota units; archive transfers reduce request count. Shared
Drive storage headroom, API usage and cleanup failures still require monitoring.

Google has announced future charges above daily thresholds with at least 90 days' notice; published
rates and activation dates must be rechecked before rollout. Sources, checked September 30, 2026:
[Drive limits](https://developers.google.com/workspace/drive/api/guides/limits) and
[Workspace API policy](https://developers.google.com/workspace/tools-safety).
