# Archive the legacy infrastructure repository

This runbook retires the old `a-novel/agora-infra` repository after the replacement production
environment has passed its live operational acceptance test. Archiving is a separate, explicit
administrator action. Nothing in this repository schedules or performs it.

[GitHub archival](https://docs.github.com/en/repositories/archiving-a-github-repository/archiving-repositories)
makes a repository read-only and can be reversed by an administrator. GitHub recommends closing
open issues and pull requests and updating the README and description first. Archival is a source
governance control, not a cloud shutdown or credential-revocation mechanism, so this procedure
removes those capabilities before it archives the source.

## Safety contract

- Archive exactly `a-novel/agora-infra`; never infer a renamed repository and never substitute
  `a-novel/infra`.
- Stop unless [`a-novel/.github#277`](https://github.com/a-novel/.github/issues/277) is closed. That
  task remains open until hosted SMTP, alert delivery, both clean-room database restores, public and
  private path checks, RPO/RTO evidence, and recovery-project cleanup have passed live.
- Use a human GitHub repository administrator. Agents, workflows, and Google Cloud identities do not
  receive repository-archive authority.
- Disable legacy GitHub Actions and revoke every legacy cloud credential before archiving. Do not
  rely on the read-only archive state to stop an external system.
- Preserve only source and non-secret operational history. Never copy a state file, saved plan,
  credential, environment export, database archive, or secret payload into either public repository.
- Keep the interactive confirmation. Do not add `--yes` to the archive or unarchive command.

If the target cannot be resolved, is already archived, was renamed, or does not match the exact
owner/name below, stop and correct task #277 before changing any repository. A missing repository is
not evidence that the intended legacy system was safely retired.

## 1. Prove replacement acceptance

Run from any clean checkout with an authenticated GitHub CLI session:

```bash
set -euo pipefail

ACCEPTANCE_REPOSITORY='a-novel/.github'
ACCEPTANCE_ISSUE='277'
LEGACY_REPOSITORY='a-novel/agora-infra'
REPLACEMENT_REPOSITORY='a-novel/infra'

gh issue view "${ACCEPTANCE_ISSUE}" \
  --repo "${ACCEPTANCE_REPOSITORY}" \
  --json number,state,title,url \
  --jq '{number,state,title,url}'

[[ "$(gh issue view "${ACCEPTANCE_ISSUE}" \
  --repo "${ACCEPTANCE_REPOSITORY}" \
  --json state \
  --jq '.state')" == 'CLOSED' ]]
```

Expected safe result: the JSON names issue `277` with state `CLOSED`, and the final assertion exits
zero. An open issue is a hard stop; do not archive based on a nearly complete checklist or a merged
infrastructure pull request.

Open the issue and independently confirm that its closing evidence identifies, without secret
values:

- one unbranded Authentication message and one controlled bounce through authenticated hosted SMTP;
- tested operations and cost notification channels;
- successful latest logical backups for both databases;
- the disposable replacement project and immutable recovery receipt;
- both database restores, the public Authentication path, and private JSON Keys path;
- measured RPO no greater than six hours and RTO no greater than 90 minutes; and
- the replacement project in `DELETE_REQUESTED` after cross-project access was removed.

Do not treat a comment, screenshot, or issue closure as a substitute for the receipt and workflow
links required by the owning runbooks.

## 2. Prove the exact target and administrator

```bash
gh repo view "${LEGACY_REPOSITORY}" \
  --json nameWithOwner,isArchived,visibility,defaultBranchRef,url,viewerPermission \
  --jq '{nameWithOwner,isArchived,visibility,defaultBranch:.defaultBranchRef.name,url,viewerPermission}'

[[ "$(gh repo view "${LEGACY_REPOSITORY}" --json nameWithOwner --jq '.nameWithOwner')" == \
  "${LEGACY_REPOSITORY}" ]]
[[ "$(gh repo view "${LEGACY_REPOSITORY}" --json isArchived --jq '.isArchived')" == 'false' ]]
[[ "$(gh repo view "${LEGACY_REPOSITORY}" --json viewerPermission --jq '.viewerPermission')" == \
  'ADMIN' ]]

[[ "$(gh repo view "${REPLACEMENT_REPOSITORY}" --json isArchived --jq '.isArchived')" == 'false' ]]
```

Expected safe result: the legacy object reports the exact `a-novel/agora-infra` name, an active
repository, and `ADMIN`; the replacement repository also remains active. The default branch and
visibility are informational and must not be used to guess another target.

## 3. Remove operational dependencies

Before changing the legacy repository, complete and record this checklist in task #277:

1. Production DNS, deployments, drift checks, backups, restores, and incident procedures refer only
   to `a-novel/infra` and its protected identities.
2. Every legacy cloud access key, deploy key, workload-federation trust, webhook credential, and
   third-party deployment token has been revoked at its issuer. Listing or deleting a GitHub secret
   alone does not revoke the credential it contains.
3. Any unique, still-correct explanation has moved through a reviewed pull request. State, plans,
   logs, database exports, and credentials have not moved.
4. The legacy README starts with a deprecation notice linking to `a-novel/infra`; its description
   says that it is archived and replaced. Land that change before archival because archived content
   is read-only.

Inventory names and timestamps without printing secret values:

```bash
gh secret list --repo "${LEGACY_REPOSITORY}" --app actions \
  --json name,updatedAt --jq 'sort_by(.name)'
gh secret list --repo "${LEGACY_REPOSITORY}" --app dependabot \
  --json name,updatedAt --jq 'sort_by(.name)'
gh variable list --repo "${LEGACY_REPOSITORY}" \
  --json name,updatedAt --jq 'sort_by(.name)'

gh api "repos/${LEGACY_REPOSITORY}/environments" \
  --jq '[.environments[] | {name,protection_rules:(.protection_rules | length)}] | sort_by(.name)'

while IFS= read -r environment; do
  gh secret list --repo "${LEGACY_REPOSITORY}" --env "${environment}" \
    --json name,updatedAt --jq 'sort_by(.name)'
  gh variable list --repo "${LEGACY_REPOSITORY}" --env "${environment}" \
    --json name,updatedAt --jq 'sort_by(.name)'
done < <(gh api "repos/${LEGACY_REPOSITORY}/environments" \
  --jq '.environments[].name')
```

Expected safe result: metadata only. Do not paste this inventory into a public issue if even a name
reveals an account, host, or customer.

Revocation is provider-specific because the legacy repository may have used more than one issuer.
Have a second maintainer verify each issuer's audit trail. Put sensitive identifiers and audit
evidence only in the restricted operational record; the public task records the revocation time,
verifier, and pass/fail result. If any credential's issuer or status is unknown, stop.

After the deprecation pull request is merged, set the repository description:

```bash
gh repo edit "${LEGACY_REPOSITORY}" \
  --description 'Archived legacy infrastructure; replaced by https://github.com/a-novel/infra'

gh repo view "${LEGACY_REPOSITORY}" --json description --jq '.description'
```

Expected safe result:

```text
Archived legacy infrastructure; replaced by https://github.com/a-novel/infra
```

## 4. Drain collaboration and execution

GitHub recommends closing issues and pull requests before archiving. Transfer anything still valid
to the owning repository, keep a cross-link, and then require empty open queues:

```bash
gh pr list --repo "${LEGACY_REPOSITORY}" --state open --limit 1000 \
  --json number,title,url --jq '.'
gh issue list --repo "${LEGACY_REPOSITORY}" --state open --limit 1000 \
  --json number,title,url --jq '.'
gh run list --repo "${LEGACY_REPOSITORY}" --all --limit 100 \
  --json databaseId,workflowName,status,conclusion,url \
  --jq '[.[] | select(.status != "completed")]'
```

Expected safe result: `[]` from all three commands. Handle the complete open set before continuing.

Disable Actions through GitHub's repository setting, then verify it independently:

```bash
gh api --method PUT "repos/${LEGACY_REPOSITORY}/actions/permissions" -F enabled=false
gh api "repos/${LEGACY_REPOSITORY}/actions/permissions" --jq '{enabled}'
```

Expected safe result: the write returns no body and the verification prints `{"enabled":false}`.
If an organization policy prevents the repository setting, have an organization owner disable it
and repeat the read. Do not archive while Actions remains enabled.

Repeat the active-run query after disabling Actions. It must still return `[]`.

## 5. Archive with human confirmation

Review the target one final time, then invoke GitHub CLI without the confirmation-bypass flag:

```bash
gh repo view "${LEGACY_REPOSITORY}" --json nameWithOwner,isArchived,url \
  --jq '{nameWithOwner,isArchived,url}'
gh repo archive "${LEGACY_REPOSITORY}"
```

The first command must still show exactly `a-novel/agora-infra` and `isArchived:false`. Read the CLI
warning and confirm interactively only after comparing the full owner/name with task #277.

Verify the result in a separate request:

```bash
gh repo view "${LEGACY_REPOSITORY}" --json nameWithOwner,isArchived,archivedAt,url \
  --jq '{nameWithOwner,isArchived,archivedAt,url}'
```

Expected safe result: the exact target, `isArchived:true`, and a non-null archive timestamp. Add the
verification URL and timestamp to task #277; do not reopen the task merely to add this postscript.

## Recovery from a wrong or premature archive

An administrator can unarchive the repository. Do so only when the target was wrong or a specific
missing record blocks incident response:

```bash
gh repo view "${LEGACY_REPOSITORY}" --json nameWithOwner,isArchived,url \
  --jq '{nameWithOwner,isArchived,url}'
gh repo unarchive "${LEGACY_REPOSITORY}"
```

Keep the interactive confirmation. Record why the archive was reversed, retrieve or migrate only
the missing non-secret material through review, and rerun every check in this runbook before
archiving again. Do not re-enable legacy Actions or restore legacy credentials, and never resume a
production deployment from this repository.

GitHub's [repository-role reference](https://docs.github.com/en/organizations/managing-user-access-to-your-organizations-repositories/managing-repository-roles/repository-roles-for-an-organization)
documents the required administrator role. The
[`gh repo archive` manual](https://cli.github.com/manual/gh_repo_archive) and
[`gh repo unarchive` manual](https://cli.github.com/manual/gh_repo_unarchive) document the two
interactive commands.
