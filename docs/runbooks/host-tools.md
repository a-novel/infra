# Host tools

This runbook covers the two programs this repository builds for the VMs: how they are tested,
published, verified and pinned. Everything else that runs in production comes from the service
repositories.

| Tool               | Runs on                                     | Does                                                                                                                                                                 |
| ------------------ | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `host-credentials` | database hosts and backup repository VMs    | Before PostgreSQL or the pgBackRest server starts, checks the VM's identity, reads its pinned TLS secrets, checks them, and writes them where pgBackRest reads them. |
| `native-restore`   | the [recovery](recovery.md) drill host only | Restores one exact backup set offline, checks the database identity, then runs the service's schema checks with no network.                                          |

Their code is in `cmd/` and `internal/`, and their Dockerfiles in `builds/`. Every pull request
builds and scans both images, runs their Go tests, and runs the [backup tests](../../tests/backup/README.md)
inside both database images. Merging deploys neither: a new version reaches the VMs only once you
publish it and pin its digest.

## Publish a version

Publishing is off by default, and each tool has its own switch.

1. **Turn publishing on** for the tool, as a repository admin: set the repository variable
   `HOST_CREDENTIALS_PUBLICATION_ENABLED` or `NATIVE_RESTORE_PUBLICATION_ENABLED` to `true`.
2. **Run the workflow** on `master`:

   ```bash
   gh workflow run publish-rollout-verifier.yaml --repo a-novel/infra --ref master -f tool=host-credentials -f publish=true
   ```

   It builds and scans the image again, then waits for approval of the `host-artifacts` environment.
   With `publish=false` it only builds and scans.

3. **Approve the deployment** in the run, after checking the tool, its source commit and the scan.
   The scanned image is kept one day: past that, start a new run. The run pushes that exact image to
   `ghcr.io/a-novel/infra/<tool>`, attests it, and prints its digest in the summary.
4. **Turn publishing off** again by removing the variable.

Keep the workflow's file name: it is part of the attestation's signer identity.

## Verify the published image

Use the digest and commit from the run summary, never a tag:

```bash
TOOL=host-credentials TOOL_DIGEST=sha256:<from the run summary> TOOL_COMMIT=<source commit>
gh attestation verify "oci://ghcr.io/a-novel/infra/$TOOL@$TOOL_DIGEST" --repo a-novel/infra \
  --signer-workflow a-novel/infra/.github/workflows/publish-rollout-verifier.yaml \
  --source-ref refs/heads/master --source-digest "$TOOL_COMMIT" --deny-self-hosted-runners
```

An attestation proves where the image comes from, not that its run succeeded: check the run too. If
attestation failed after the push, the pushed image is incomplete: publish again.

## Pin `host-credentials`

The hosts pull it from each service's private tooling repository in Artifact Registry,
`agora-<service>-private-tooling`, by digest only. The copy keeps the digest; its tag only names the
source commit. The deploy copies only service and database
images, so a person copies this one. No standing human role may write there: an organization admin
grants it for the copy, and removes it right after.

```bash
ME="user:$(gcloud config get-value account)"
gcloud projects add-iam-policy-binding "$PROD" --role=roles/artifactregistry.writer --member="$ME" --condition=None
for SERVICE in json-keys authentication; do
  skopeo copy --all --preserve-digests --dest-creds="oauth2accesstoken:$(gcloud auth print-access-token)" \
    "docker://ghcr.io/a-novel/infra/host-credentials@$TOOL_DIGEST" \
    "docker://europe-west1-docker.pkg.dev/$PROD/agora-$SERVICE-private-tooling/host-credentials:$TOOL_COMMIT"
done
gcloud projects remove-iam-policy-binding "$PROD" --role=roles/artifactregistry.writer --member="$ME" --condition=None
```

Then pin the digest in four places, in one pull request:

| Root           | Key                                                                                             |
| -------------- | ----------------------------------------------------------------------------------------------- |
| foundation     | `native_backups.json-keys.credentials_image`, `native_backups.authentication.credentials_image` |
| json-keys      | `backup_repository.runtime.credentials_image`                                                   |
| authentication | `backup_repository.runtime.credentials_image`                                                   |

The foundation pins change the database hosts, so merge the pull request as a
[database host change](database.md#change-a-database-host), during a planned downtime. The rollout
restarts each database host, then its backup repository VM, which load the new version.

## Pin `native-restore`

Nothing in production runs it. A recovery drill copies it into the drill project and passes its
digest in the drill's input: see [Recovery](recovery.md#2-create-the-drill-project).
