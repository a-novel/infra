# Connect the invitation list

Authentication signs requests to a private Google Sheets writer. Complete the
[Apps Script setup](https://github.com/a-novel/service-authentication/tree/master/scripts/waitlist)
before this runbook. Keep separate sheets, script projects, keys, and deployment URLs for test
and production. Verify the copied script's `WAITLIST_SPREADSHEET_ID` before sending test requests.

## Provision the production key

Merge the reviewed infrastructure change, then follow
[Start an operation](./README.md#start-an-operation). For an existing installation, use the
[protected foundation plan/apply workflow](../../ops/README.md#protected-workflow-operations) for
the `bootstrap` root first, then the `foundation` root. Review and apply each saved plan before
continuing. Do not rerun the one-time management bootstrap.

This creates `production-authentication-waitlist-secret` and grants the production Authentication
runtime access. No payload version is created by OpenTofu. Do not configure Cloud Run manually.

Follow the operator context and prerequisites in [Secret versions](./secret-versions.md).
From the infrastructure repository, in that private terminal session, run:

```sh
./ops/add-secret-version.sh production-authentication-waitlist-secret
```

Paste the production script's signing key at both hidden prompts. Record the returned numeric
version in the private deployment record. Keep the key out of chat, GitHub, release inputs,
environment files, and command arguments. The test key stored locally is not used in production.

## Configure the release

Update the `authentication/public-api` entry in the protected native release configuration.
Merge this fragment into the existing entry, preserving all other fields and secret references:

```json
{
  "authentication": {
    "waitlist_url": "https://script.google.com/macros/s/REPLACE_WITH_PRODUCTION_DEPLOYMENT_ID/exec"
  },
  "secret_versions": {
    "waitlist-secret": 1
  }
}
```

Replace the example URL with the production `/exec` URL and `1` with the uploaded version.
The URL must have no query, fragment, credentials, or development `/dev` suffix. Keep the real
URL in private operator inputs. Only the numeric version belongs in `secret_versions`; never include the signing key.

Store the complete map as `SERVICE_JOB_BOOTSTRAPS_JSON` in the `production-foundation` environment,
following [the release configuration procedure](./deploy-production.md#4-store-the-protected-non-payload-release-configuration).
Deploy and verify an Authentication candidate, then review its traffic promotion. Leave the other
service's configuration unchanged.
Preflight checks the selected secret version's metadata without reading its payload.

Only Authentication REST receives `WAITLIST_URL` and `WAITLIST_SECRET`; its default request timeout
remains ten seconds. The existing private-ranges-only egress permits Google's public endpoint.
Database, migration, initialization, backup, and JSON Keys runtimes receive neither variable.
Clean-room recovery omits both variables and the waitlist IAM grant even when its receipt contains
waitlist configuration. No cleanup job or schedule is provisioned by this change.

## Verify and recover

First run the service's documented smoke checks against the separate test deployment. Production
checks require operator approval and a controlled address. Confirm one new row, no additional row
for a duplicate, no row for an existing account, and removal after account completion. Retain only
status/count evidence; keep sheet contents, signing keys, and signed requests out of logs.

The general healthcheck does not probe the waitlist. A healthy service therefore does not prove
the script permissions, signing key, or sheet configuration are correct. Check the actual flow.

Omit `authentication.waitlist_url`, or set it to `null`, to disable intake in a new release. Existing
release receipts preserve their endpoint and key version; rollback uses those exact values, and a
receipt without waitlist configuration leaves it disabled. Preserve referenced key versions during
the rollback window.

Apps Script accepts one signing key at a time. Rotation requires a coordinated change to its
Script Properties and Authentication's pinned version; requests can fail during the mismatch.
Reverting the service alone does not revert Script Properties. Restore the matching script key
before relying on an older receipt. Account creation survives cleanup failures; reconcile missed
rows using the service's existing operator-only `waitlist-cleanup` command after recovery.
