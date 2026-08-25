# Add or rotate a secret version

OpenTofu owns Secret Manager containers and IAM; it never owns payload versions. A named human
operator supplies one single-line payload through stdin after the management plane exists. The
payload must never appear in Git, a `.tfvars` file, an environment file, a command argument, shell
history, process listings, OpenTofu state, a GitHub secret, an issue, or logs.

Operators have two roles on each exact application secret: Secret Accessor for controlled recovery
and Secret Version Manager for add, disable, re-enable, and delayed destroy. Automation has none of
those permissions except the separately approved recovery identity, which can read the seven exact
secrets. See [Secret Manager access control](https://cloud.google.com/secret-manager/docs/access-control),
[adding versions](https://cloud.google.com/secret-manager/docs/add-secret-version), and
[delayed destruction](https://cloud.google.com/secret-manager/docs/delay-destruction-of-secret-versions).

## Preconditions

- Complete the [management-plane bootstrap](./bootstrap-management-plane.md).
- Use the declared operator Google account with MFA in a private, non-recorded Bash session.
- Obtain or generate the value in an approved password manager. Do not ask an agent to generate,
  transmit, or retain it.
- Know the one exact secret ID and its runtime format. DSNs and passwords are different values even
  when they refer to the same database.
- A PostgreSQL password must contain 32–128 characters from `A-Z`, `a-z`, `0-9`, `_`, and `-` only.
  This printable URL-safe contract makes byte-exact validation and direct DSN embedding unambiguous.
  JSON Keys and Authentication must use different values.
- For rotation, know every consumer and the currently pinned numeric version. Never configure a
  production consumer to use the mutable `latest` alias.

The allowed IDs are:

```text
production-authentication-postgres-dsn
production-authentication-postgres-password
production-authentication-smtp-sender-password
production-authentication-super-admin-password
production-json-keys-app-master-key
production-json-keys-postgres-dsn
production-json-keys-postgres-password
```

## Add one version safely

Start a fresh Bash session, disable tracing, and select the project and one allowed secret. Shell
history records these identifier-only commands, never the value typed at the hidden prompts.

```bash
set -euo pipefail
set +x
umask 077

read -r -p 'Management project ID: ' MANAGEMENT_PROJECT_ID
read -r -p 'Exact secret ID: ' SECRET_ID

case "${SECRET_ID}" in
  production-authentication-postgres-dsn|\
  production-authentication-postgres-password|\
  production-authentication-smtp-sender-password|\
  production-authentication-super-admin-password|\
  production-json-keys-app-master-key|\
  production-json-keys-postgres-dsn|\
  production-json-keys-postgres-password) ;;
  *) printf 'Refusing undeclared secret ID.\n' >&2; false ;;
esac

gcloud secrets describe "${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --format='yaml(name,annotations,createTime,versionDestroyTtl)'
```

Expected safe result: the resource name ends in the selected ID, its annotation names the expected
runtime contract, and `versionDestroyTtl` is 30 days. No payload is shown.

Read the value twice with terminal echo disabled. This procedure supports the application's
single-line string contracts; a newline is not appended to the stored value.

```bash
IFS= read -r -s -p 'Secret value: ' SECRET_VALUE
printf '\n' >&2
IFS= read -r -s -p 'Repeat secret value: ' SECRET_VALUE_CONFIRMATION
printf '\n' >&2

test -n "${SECRET_VALUE}"
test "${SECRET_VALUE}" = "${SECRET_VALUE_CONFIRMATION}"

case "${SECRET_ID}" in
  production-authentication-postgres-password|production-json-keys-postgres-password)
    test "${#SECRET_VALUE}" -ge 32
    test "${#SECRET_VALUE}" -le 128
    [[ "${SECRET_VALUE}" =~ ^[A-Za-z0-9_-]+$ ]]
    ;;
esac

unset SECRET_VALUE_CONFIRMATION
```

If an equality or PostgreSQL-format check fails, Bash exits before contacting Google. Restart the
procedure; do not echo either variable to diagnose it.

Add the version through stdin and retain only the numeric version identifier:

```bash
VERSION_ID="$({
  printf '%s' "${SECRET_VALUE}"
} | gcloud secrets versions add "${SECRET_ID}" \
    --project="${MANAGEMENT_PROJECT_ID}" \
    --data-file=- \
    --format='value(name.basename())')"

unset SECRET_VALUE
[[ "${VERSION_ID}" =~ ^[0-9]+$ ]]
printf 'Created %s version %s\n' "${SECRET_ID}" "${VERSION_ID}"
```

Expected safe result: one numeric version ID. The payload is neither a command argument nor output.
If the command fails before returning an ID, clear the variables and retry; Secret Manager assigns a
new immutable number to each successful add, so first list metadata to avoid creating an unexplained
duplicate.

Verify metadata only:

```bash
gcloud secrets versions describe "${VERSION_ID}" \
  --secret="${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --format='yaml(name,state,createTime,destroyTime,scheduledDestroyTime)'

gcloud secrets versions list "${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --format='table(name.basename(),state,createTime,destroyTime)'
```

Expected safe result: the new numeric version is `ENABLED` with a creation time and no destruction
time. Do not run `gcloud secrets versions access` merely to print-test it. The two hidden-entry check
validated the input without disclosing it.

Record only this non-secret tuple in the private deployment record: project ID, secret ID, numeric
version, operator, timestamp, and reason. Do not record the value or a reversible encoding.

## Initial population

Repeat the add procedure separately for every secret needed by the next reviewed workload change.
Do not populate unused containers early. Authentication and JSON Keys currently require the seven
declared contracts; database DSNs must use the stateful private address and distinct host ports from
the [PostgreSQL host runbook](./operate-postgresql-host.md), so create those versions only after the
foundation output is known.

The initial application release must pin each numeric version. Treat a missing version as a blocked
deployment, not a reason to use `latest` or copy a value into GitHub.

## Rotate through a controlled rollout

The normal sequence is additive when a consumer and credential issuer support an overlap window:

1. Add and record a new enabled version using the procedure above.
2. Update the foundation/release code or manifest to reference that exact numeric version.
3. Merge and deploy in the required database → services → platform order.
4. Verify all consumers and background jobs use the new version.
5. Disable the old version; keep it recoverable during the observation window.
6. Destroy it only after the rollback window and any external credential revocation are complete.

Do not assume this sequence is zero-downtime. A PostgreSQL password is the credential enforced by
the running cluster, so changing the database password and the client DSN is one coordinated
rollout. Follow the PostgreSQL host runbook, schedule the documented short interruption, update the
database before its clients, and keep the previous numeric password and DSN versions available for
rollback. Credentials whose issuer supports two concurrently valid values can use a true overlap
window instead.

Select the old numeric version explicitly and compare it with the new one:

```bash
read -r -p 'Old numeric version to disable: ' OLD_VERSION_ID
[[ "${OLD_VERSION_ID}" =~ ^[0-9]+$ ]]
test "${OLD_VERSION_ID}" != "${VERSION_ID}"

gcloud secrets versions describe "${OLD_VERSION_ID}" \
  --secret="${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --format='yaml(name,state,createTime)'
```

After deployment evidence confirms no consumer uses it:

```bash
gcloud secrets versions disable "${OLD_VERSION_ID}" \
  --secret="${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --quiet \
  --format='yaml(name,state)'
```

Expected safe result: the exact old version is `DISABLED`. If a rollback needs it, re-enable that
same version and redeploy the prior receipt:

```bash
gcloud secrets versions enable "${OLD_VERSION_ID}" \
  --secret="${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --quiet \
  --format='yaml(name,state)'
```

Expected safe result: `ENABLED`. Re-enabling changes no payload.

## Delayed destruction

Destroy only a disabled version after its documented rollback window. Secret Manager's configured
30-day delay means the destroy request schedules deletion instead of immediately erasing the payload.
This is still a production-destructive action and requires a reviewed recovery record.

```bash
gcloud secrets versions describe "${OLD_VERSION_ID}" \
  --secret="${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --format='yaml(name,state,createTime)'

read -r -p "Type ${SECRET_ID}/${OLD_VERSION_ID} to schedule destruction: " CONFIRM_DESTROY
test "${CONFIRM_DESTROY}" = "${SECRET_ID}/${OLD_VERSION_ID}"

gcloud secrets versions destroy "${OLD_VERSION_ID}" \
  --secret="${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --quiet \
  --format='yaml(name,state,scheduledDestroyTime)'
```

Expected safe result: a scheduled destruction time approximately 30 days ahead. During that delay,
use the documented Secret Manager restore/cancel behavior if the version was selected incorrectly;
after final destruction the payload is irrecoverable.

For an externally valid credential such as SMTP, disabling the Secret Manager version does not revoke
the credential at its issuer. Rotate and revoke it at the provider as a separate operator action,
then verify both systems. Database passwords likewise require a coordinated PostgreSQL credential
change before the old Secret Manager version is disabled.

## Audit and cleanup

Query audit metadata without payloads:

```bash
gcloud logging read \
  'protoPayload.serviceName="secretmanager.googleapis.com" AND protoPayload.resourceName:"/secrets/'"${SECRET_ID}"'"' \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --limit=20 \
  --format='table(timestamp,protoPayload.methodName,protoPayload.authenticationInfo.principalEmail)'
```

Expected safe result: add/disable/enable/destroy metadata attributed to the named operator. Secret
Manager audit records do not include payloads.

Clear the remaining identifiers and close the private shell:

```bash
unset MANAGEMENT_PROJECT_ID SECRET_ID VERSION_ID OLD_VERSION_ID CONFIRM_DESTROY
unset SECRET_VALUE SECRET_VALUE_CONFIRMATION
```

If shell tracing was ever enabled or a payload appeared on screen, treat the value as compromised:
rotate immediately, disable the exposed version after consumers move, revoke it at any external
issuer, and record the incident without reproducing the value.
