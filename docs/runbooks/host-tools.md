# Host tools

This runbook is about the two programs this repository builds for the VMs. Everything else that runs
in production comes from the service repositories.

| Tool               | Runs on                                     | Role                                                                                            |
| ------------------ | ------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `host-credentials` | database hosts and backup repository VMs    | Loads and checks the host's pinned pgBackRest TLS files before PostgreSQL or pgBackRest starts. |
| `native-restore`   | the [recovery](recovery.md) drill host only | Restores one exact backup set offline, then runs the service's schema checks with no network.   |

Their code is in `cmd/` and `internal/`, and their Dockerfiles in `builds/`. Every pull request
builds and scans both images and runs their Go tests. It also runs the
[backup tests](../../tests/backup/README.md) inside the database image of each service with native
backups. Merging deploys neither tool. A new version reaches the VMs only once you publish it and
pin it.

## Publish a version

Publishing is off by default, and each tool has its own switch.

1. **Turn publishing on** for the tool, as a repository admin. For `native-restore`, the switch is
   `NATIVE_RESTORE_PUBLICATION_ENABLED`.

   ```bash
   TOOL=host-credentials
   SWITCH=HOST_CREDENTIALS_PUBLICATION_ENABLED
   gh variable set "$SWITCH" --repo a-novel/infra --body true
   ```

2. **Run the workflow** on `master`. It builds and scans the image again, then waits for approval of
   the `host-artifacts` environment. With `publish=false` it only builds and scans.

   ```bash
   gh workflow run publish-rollout-verifier.yaml --repo a-novel/infra --ref master \
     -f tool="$TOOL" -f publish=true
   ```

3. **Approve the deployment** with **Review deployments** on the run's page, after checking the
   tool, its source commit and the scan. The scanned image is kept one day, so past that, start a
   new run. The run pushes that exact image to `ghcr.io/a-novel/infra/<tool>`, attests it, and
   prints its digest in the summary.
4. **Turn publishing off** again:

   ```bash
   gh variable delete "$SWITCH" --repo a-novel/infra
   ```

Keep the workflow's file name. It is part of the attestation's signer identity.

## Verify the published image

Use the digest and commit from the run summary, never a tag:

```bash
TOOL=host-credentials
TOOL_DIGEST="sha256:<from the run summary>"
TOOL_COMMIT="<source commit>"
gh attestation verify "oci://ghcr.io/a-novel/infra/$TOOL@$TOOL_DIGEST" --repo a-novel/infra \
  --signer-workflow a-novel/infra/.github/workflows/publish-rollout-verifier.yaml \
  --source-ref refs/heads/master --source-digest "$TOOL_COMMIT" --deny-self-hosted-runners
```

An attestation proves where the image comes from. It does not prove its run succeeded, so check
the run too. If attestation failed after the push, the pushed image is incomplete. Publish again.

## Pin `host-credentials`

Foundation pins the published image once, in `host_credentials_image`, as
`ghcr.io/a-novel/infra/host-credentials:sha-<commit>-<run ID>-<run attempt>@<digest>`. The tag is
the one the run pushed, and the digest the one its summary prints. Every plan that changes the pin
verifies its attestation against `publish-rollout-verifier.yaml`. The deploy then copies it into
each service's private tooling repository, `agora-<service>-private-tooling`, and the hosts pull it
from there, by digest.

The service roots read that reference from foundation for their backup repository VMs, so this one
value is the only pin.

A new pin changes the database hosts, so merge its pull request as a
[database host change](database.md#change-a-database-host), during a planned downtime. The deploy
copies the image before it applies. The rollout then restarts each database host, then its backup
repository VM, which load the new version.

## Pin `native-restore`

Nothing in production runs it. A recovery drill copies it into the drill project and passes its
digest in the drill's input, as [Recovery](recovery.md#2-create-the-drill-project) describes.
