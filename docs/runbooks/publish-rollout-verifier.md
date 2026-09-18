# Publish the rollout verifier

This publishes a tooling image to GHCR. It does not access Google Cloud, promote an image into a
workload project, approve a rollout or change production. The Cloud Deploy pilot remains suspended.

The existing `scan-infrastructure` CI check builds and scans the verifier on every PR. The manual
`publish-rollout-verifier.yaml` workflow uses the same action, with publication off by default.
Its read-only build job exports one `linux/amd64` Docker image and fails on high/critical
vulnerabilities or secrets. A separate publishing job receives that exact archive by artifact ID,
checks its archive digest through GitHub's artifact action, pushes it without rebuilding, and attests
the registry digest.
The publishing runner never checks out or executes repository code.

## Build and scan only

After the workflow has merged, run this against reviewed `master`:

```sh
gh workflow run publish-rollout-verifier.yaml --repo a-novel/infra --ref master -f publish=false
```

This mode needs no environment approval, publication switch or cloud credentials. A passing scan
establishes artifact buildability and the current scanner verdict, not private probe connectivity or
successful Cloud Deploy verification. Those require the separately approved live pilot.

## Enable publication once approved

A maintainer first configures the `rollout-artifacts` GitHub environment with required reviewers,
protected-branch access and administrator bypass disabled. The workflow cannot enforce those external
settings by naming an environment: inspect them before enabling publication.

```sh
gh api repos/a-novel/infra/environments/rollout-artifacts --jq '{name,can_admins_bypass,deployment_branch_policy,protection_rules}'
```

Stop if the environment is absent, lacks its reviewer gate, permits bypass, or allows unreviewed
branches. Confirm `master` is protected. Then explicitly enable this artifact-only workflow:

```sh
gh variable set ROLLOUT_VERIFIER_PUBLICATION_ENABLED --repo a-novel/infra --body true
gh workflow run publish-rollout-verifier.yaml --repo a-novel/infra --ref master -f publish=true
```

Approve the exact run's `rollout-artifacts` deployment only after reviewing its source commit and
successful build/scan. The scanned archive expires after one day; an expired artifact requires a new
build and approval. No workflow is dispatched or setting changed by merging this code.

The successful run summary contains `ghcr.io/a-novel/infra/rollout-verifier@sha256:…` and its source
commit. The tag includes the source commit, run ID and attempt for navigation; consumers pin the digest.
Publication has only repository-read, package-write, attestation-write and signing-token permissions.
It has no Google federation login or production environment access.

## Verify before promotion

Set these two values from the reviewed, successful publication run. Do not resolve a mutable tag or
select the latest image:

```sh
VERIFIER_DIGEST='sha256:<64 hexadecimal characters from the successful run>'
VERIFIER_COMMIT='<40-character reviewed source commit>'
gh attestation verify "oci://ghcr.io/a-novel/infra/rollout-verifier@${VERIFIER_DIGEST:?}" \
  --repo a-novel/infra \
  --signer-workflow a-novel/infra/.github/workflows/publish-rollout-verifier.yaml \
  --source-ref refs/heads/master --source-digest "${VERIFIER_COMMIT:?}" \
  --deny-self-hosted-runners
```

Use an authenticated registry session if GHCR package visibility requires it. The maintainer must
also confirm the publication run succeeded: an attestation alone records origin, not every approval
or the current vulnerability status.

Promotion into the selected project's regional Artifact Registry is a separate approved operation.
Preserve and verify the source digest, then pin the same destination digest in the Cloud Deploy worker
and probe. Keep referenced images and attestations available for retained rollouts and rollback.

## Interrupted publication

A pushed image can remain when attestation or reporting fails. Treat that attempt as incomplete;
do not select it for promotion from the tag alone. Inspect the exact run and digest. Retrying the
publication job only re-pushes its scanned image and signs it; an expired archive needs a fresh build.
There is no automatic retry or artifact deletion. This recovery path never submits a deployment or
reruns a database migration.

To stop future publications, remove the explicit opt-in:

```sh
gh variable delete ROLLOUT_VERIFIER_PUBLICATION_ENABLED --repo a-novel/infra
```

This does not cancel an already running publisher or delete any image. Leave it unset until approved.

References: [Docker image transfer](https://docs.docker.com/build/ci/github-actions/share-image-jobs/),
[GitHub artifact attestations](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations),
and [verification constraints](https://cli.github.com/manual/gh_attestation_verify).
