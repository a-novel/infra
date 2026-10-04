# Publish infrastructure tooling

This publishes one reviewed tooling image to GHCR. Cloud promotion and host activation
require separate approval. The workflow has no Google Cloud credentials.

The `scan-infrastructure` CI check builds and scans all tools on every PR. The manual
`publish-rollout-verifier.yaml` workflow uses the same action, with publication off by default.
Its filename remains stable because it identifies the retained tools' provenance signer.
Its read-only build job exports one `linux/amd64` Docker image and fails on high/critical
vulnerabilities or secrets. A separate publishing job receives that exact archive by artifact ID,
checks its archive digest through GitHub's artifact action, pushes it without rebuilding, and attests
the registry digest.
The publishing runner never checks out or executes repository code.

## Select the tool

The workflow defaults to `host-credentials`. Each tool has an independent publication opt-in.

| Tool               | Repository variable                    | Approval environment |
| ------------------ | -------------------------------------- | -------------------- |
| `host-credentials` | `HOST_CREDENTIALS_PUBLICATION_ENABLED` | `host-artifacts`     |
| `native-restore`   | `NATIVE_RESTORE_PUBLICATION_ENABLED`   | `host-artifacts`     |

For the credential loader, use:

```sh
TOOL=host-credentials
PUBLICATION_SWITCH=HOST_CREDENTIALS_PUBLICATION_ENABLED
ARTIFACT_ENV=host-artifacts
```

For another tool, select all three values from its row. Publication neither reads TLS secrets
nor starts hosts. The restore worker carries JSON Keys' PostgreSQL image; its system libraries
and extensions are part of the scan and compatibility review.

## Build and scan only

After the workflow has merged, run this against reviewed `master`:

```sh
gh workflow run publish-rollout-verifier.yaml --repo a-novel/infra --ref master \
  -f tool="${TOOL:?}" -f publish=false
```

This mode needs no environment approval, publication switch or cloud credentials. A passing scan
establishes artifact buildability and the current scanner verdict. Host credential delivery,
repository confinement and SQL recovery require their separately approved live proofs.

## Enable publication once approved

A maintainer first configures the selected GitHub environment with required reviewers,
protected-branch access and administrator bypass disabled. The workflow cannot enforce those external
settings by naming an environment: inspect them before enabling publication.

```sh
gh api "repos/a-novel/infra/environments/${ARTIFACT_ENV:?}" \
  --jq '{name,can_admins_bypass,deployment_branch_policy,protection_rules}'
```

Stop if the environment is absent, lacks its reviewer gate, permits bypass, or allows unreviewed
branches. Confirm `master` is protected. Review GHCR package access too: these workflow gates do
not make the repository's package-write token an image-scoped credential. Then enable only the
selected tool:

```sh
gh variable set "${PUBLICATION_SWITCH:?}" --repo a-novel/infra --body true
gh workflow run publish-rollout-verifier.yaml --repo a-novel/infra --ref master \
  -f tool="${TOOL:?}" -f publish=true
```

Approve the exact run's selected environment deployment only after reviewing its tool, source commit and
successful build/scan. The scanned archive expires after one day; an expired artifact requires a new
build and approval. No workflow is dispatched or setting changed by merging this code.

The successful run summary contains `ghcr.io/a-novel/infra/<tool>@sha256:…` and its source
commit. Generated attempt tags identify that run; promotion and runtime records retain its digest.
Maintained image dependencies continue to use SemVer.
Publication has only repository-read, package-write, attestation-write and signing-token permissions.
It has no Google federation login or production environment access.

## Verify before promotion

Set these two values from the reviewed, successful publication run. Do not resolve a mutable tag or
select the latest image:

```sh
TOOL_DIGEST='sha256:<64 hexadecimal characters from the successful run>'
TOOL_COMMIT='<40-character reviewed source commit>'
gh attestation verify "oci://ghcr.io/a-novel/infra/${TOOL:?}@${TOOL_DIGEST:?}" \
  --repo a-novel/infra \
  --signer-workflow a-novel/infra/.github/workflows/publish-rollout-verifier.yaml \
  --source-ref refs/heads/master --source-digest "${TOOL_COMMIT:?}" \
  --deny-self-hosted-runners
```

Use an authenticated registry session if GHCR package visibility requires it. The maintainer must
also confirm the publication run succeeded: an attestation alone records origin, not every approval
or the current vulnerability status.

Promotion into the selected project's regional Artifact Registry is a separate approved operation.
Preserve and verify the source digest in the selected consumer's reviewed runtime record. Host tooling needs reviewed
distribution and startup configuration. Keep referenced images and attestations available for rollback.

## Interrupted publication

A pushed image can remain when attestation or reporting fails. Treat that attempt as incomplete;
do not select it for promotion from the tag alone. Inspect the exact run and digest. Retrying the
publication job only re-pushes its scanned image and signs it; an expired archive needs a fresh build.
There is no automatic retry or artifact deletion. This recovery path never submits a deployment or
reruns a database migration.

To stop future publications, remove the explicit opt-in:

```sh
gh variable delete "${PUBLICATION_SWITCH:?}" --repo a-novel/infra
```

This does not cancel an already running publisher or delete any image. Leave it unset until approved.

References: [Docker image transfer](https://docs.docker.com/build/ci/github-actions/share-image-jobs/),
[GitHub artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations),
and [verification constraints](https://cli.github.com/manual/gh_attestation_verify).
