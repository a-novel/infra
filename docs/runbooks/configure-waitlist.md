# Connect the invitation list

Authentication signs requests to a private Google Sheets writer. Complete the
[Apps Script setup](https://github.com/a-novel/service-authentication/tree/master/scripts/waitlist)
before this runbook. Keep separate sheets, script projects, keys, and deployment URLs for test
and production. Verify the copied script's `WAITLIST_SPREADSHEET_ID` before sending test requests.

## Provision the production key

Merge the reviewed infrastructure change, then complete the existing
[management bootstrap](./bootstrap-management-plane.md) and protected foundation plan/apply.
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

Add `waitlist` inside `authentication` in the protected non-payload release configuration. Merge
this fragment into the existing configuration; retain its other fields:

```json
{
  "authentication": {
    "waitlist": {
      "url": "https://script.google.com/macros/s/REPLACE_WITH_PRODUCTION_DEPLOYMENT_ID/exec",
      "secret_version": 1
    }
  }
}
```

Replace the example URL with the production `/exec` URL and `1` with the uploaded version.
The URL must have no query, fragment, credentials, or development `/dev` suffix. Keep the real
URL in private operator inputs. No payload or additional `secret_versions` entry is needed.

Deploy through the existing protected release workflow described in
[Production operations](./README.md). Configuration-only changes use its maintenance path;
changes to another service's image family must not also change Authentication's configuration.
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

Omit `authentication.waitlist`, or set it to `null`, to disable intake in a new release. Existing
release receipts preserve their endpoint and key version; rollback uses those exact values, and a
receipt without waitlist configuration leaves it disabled. Preserve referenced key versions during
the rollback window.

Apps Script accepts one signing key at a time. Rotation requires a coordinated change to its
Script Properties and Authentication's pinned version; requests can fail during the mismatch.
Reverting the service alone does not revert Script Properties. Restore the matching script key
before relying on an older receipt. Account creation survives cleanup failures; reconcile missed
rows using the service's existing operator-only `waitlist-cleanup` command after recovery.
