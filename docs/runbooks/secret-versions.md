# Add or rotate a secret version

> First production run: step 5. Run the add-version procedure once per declared secret, record only
> numeric version IDs, then continue to the protected release.

OpenTofu owns Secret Manager containers and IAM; it never owns payload versions. A named human
operator supplies one single-line payload through stdin after the management plane exists. The
payload must never appear in Git, a `.tfvars` file, an environment file, a command argument, shell
history, process listings, OpenTofu state, a GitHub secret, an issue, or logs.

Operators have two roles on each exact application secret: Secret Accessor for controlled recovery
and Secret Version Manager for add, disable, re-enable, and delayed destroy. Automation has none of
those permissions. Dedicated production runtimes receive only their exact payload containers; a
human grants replacement runtimes temporary exact access during clean-room recovery and removes it
afterward. GitHub recovery automation cannot read payloads. See
[Secret Manager access control](https://cloud.google.com/secret-manager/docs/access-control),
[adding versions](https://cloud.google.com/secret-manager/docs/add-secret-version), and
[delayed destruction](https://cloud.google.com/secret-manager/docs/delay-destruction-of-secret-versions).

## Operator context

Load the published project coordinates, then run later blocks in the existing configured zsh
session:

```sh
. ./.envrc
./ops/verify-operator-env.sh --github
```

Paste this block once before adding or rotating a version:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
umask 077

REPOSITORY='a-novel/infra'
MANAGEMENT_PROJECT_ID="$INFRA_MANAGEMENT_PROJECT_ID"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

## Preconditions

- Complete the [management-plane bootstrap](./bootstrap-management-plane.md).
- Use the declared operator Google account with MFA in a private, non-recorded zsh session.
- Obtain or generate the value in an approved password manager. Do not ask an agent to generate,
  transmit, or retain it.
- Know the one exact secret ID and its runtime format. DSNs and passwords are different values even
  when they refer to the same database.
- A PostgreSQL password must contain 32–128 characters from `A-Z`, `a-z`, `0-9`, `_`, and `-` only.
  This printable URL-safe contract makes byte-exact validation and direct DSN embedding unambiguous.
  Both owner passwords and both backup passwords must be four distinct values.
- For rotation, know every consumer and the currently pinned numeric version. Never configure a
  production consumer to use the mutable `latest` alias.
- For the SMTP password, first complete the account, domain, privacy, billing-cap, and credential
  steps in [Configure hosted Plunk SMTP](./configure-hosted-smtp.md). The password is the exact
  provider-issued SMTP credential, not an API key invented from an example.

The allowed IDs are:

```text
production-authentication-postgres-dsn
production-authentication-postgres-password
production-authentication-postgres-backup-password
production-authentication-smtp-sender-password
production-authentication-super-admin-password
production-json-keys-app-master-key
production-json-keys-postgres-dsn
production-json-keys-postgres-password
production-json-keys-postgres-backup-password
```

## Add one version safely

Run the executable from the repository root with one allowed ID:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
./ops/add-secret-version.sh production-authentication-postgres-password
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The script verifies the selected management project against GitHub, checks the secret container,
and asks for the payload twice with terminal echo disabled. It sends the matching single-line value
through stdin, verifies the new version metadata, and prints only the safe secret ID and numeric
version to stdout. A failed match or PostgreSQL password-format check exits before contacting Secret
Manager.

Look for: the selected container has the expected runtime annotation and a 30-day destruction delay;
the created numeric version is `ENABLED` with no destruction time. If creation fails before an ID is
returned, list version metadata before retrying so every successful immutable version is accounted
for.

Record the non-secret project ID, secret ID, numeric version, operator, timestamp, and reason in the
private deployment record. Keep the payload only in the approved password manager.

## Initial population

This is mandatory first-production-run step 5, before the deployment runbook. Its deployment
selector verifies existing version metadata; it does not create missing payloads.

Repeat the add procedure separately for every secret needed by the next reviewed workload change.
Do not populate unused containers early. First production activation requires all nine declared
contracts, including separate read-only backup credentials. Database DSNs must use the stateful
private address and distinct host ports from the
[PostgreSQL host runbook](./operate-postgresql-host.md), so create those versions only after the
foundation output is known. Generate four independent cryptographically random owner/backup
passwords in the approved password manager using the 32–128 character contract above. Compare them
there without printing or exporting them; host startup fails closed if any pair is equal.

Prepare all nine values, then populate the containers in dependency order with one command:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
./ops/add-secret-version.sh \
  production-authentication-postgres-password \
  production-authentication-postgres-backup-password \
  production-json-keys-postgres-password \
  production-json-keys-postgres-backup-password \
  production-authentication-postgres-dsn \
  production-json-keys-postgres-dsn \
  production-authentication-smtp-sender-password \
  production-authentication-super-admin-password \
  production-json-keys-app-master-key
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Look for nine `Created <secret> version <number>` lines. If the command stops partway, inspect
version metadata and rerun it with only the remaining IDs.

The initial application release must pin each numeric version. Treat a missing version as a blocked
deployment, not a reason to use `latest` or copy a value into GitHub.

For `production-authentication-smtp-sender-password`, add only the password here. The exact SMTP
host, username, sender, and numeric version belong in protected `RELEASE_CONFIG_JSON`; the provider
account and billing record remain in the private operations register. Pass health and one
controlled no-branding delivery before enabling normal application mail.

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

A backup password is also a coordinated database release. Add its new version, update the exact
backup-version metadata, let host startup rotate the restricted role, and require an immediate backup
plus clean restore before disabling the former version. The backup job and host must reference the
same numeric version; never update only one side.

Add the replacement and select both numeric versions explicitly:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
SECRET_ID=''
./ops/add-secret-version.sh "$SECRET_ID"
gcloud secrets versions list "$SECRET_ID" \
  --project="$MANAGEMENT_PROJECT_ID" \
  --format='table(name.basename(),state,createTime)' \
  --sort-by='~createTime'
VERSION_ID=''
OLD_VERSION_ID=''
[[ "${VERSION_ID}" =~ ^[0-9]+$ ]]
[[ "${OLD_VERSION_ID}" =~ ^[0-9]+$ ]]
test "${OLD_VERSION_ID}" != "${VERSION_ID}"
test "$(gcloud secrets versions describe "${VERSION_ID}" \
  --secret="${SECRET_ID}" --project="${MANAGEMENT_PROJECT_ID}" \
  --format='value(state)')" = ENABLED

gcloud secrets versions describe "${OLD_VERSION_ID}" \
  --secret="${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --format='yaml(name,state,createTime)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

After deployment evidence confirms no consumer uses it:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud secrets versions disable "${OLD_VERSION_ID}" \
  --secret="${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --quiet \
  --format='yaml(name,state)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: the exact old version is `DISABLED`. If a rollback needs it, re-enable that
same version and redeploy the prior receipt:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud secrets versions enable "${OLD_VERSION_ID}" \
  --secret="${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --quiet \
  --format='yaml(name,state)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: `ENABLED`. Re-enabling changes no payload.

## Delayed destruction

Destroy only a disabled version after its documented rollback window. Secret Manager's configured
30-day delay means the destroy request schedules deletion instead of immediately erasing the payload.
This is still a production-destructive action and requires a reviewed recovery record.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud secrets versions describe "${OLD_VERSION_ID}" \
  --secret="${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --format='yaml(name,state,createTime)'

printf 'Type %s/%s to schedule destruction: ' "$SECRET_ID" "$OLD_VERSION_ID"
IFS= read -r CONFIRM_DESTROY
test "${CONFIRM_DESTROY}" = "${SECRET_ID}/${OLD_VERSION_ID}"

gcloud secrets versions destroy "${OLD_VERSION_ID}" \
  --secret="${SECRET_ID}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --quiet \
  --format='yaml(name,state,scheduledDestroyTime)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: a scheduled destruction time approximately 30 days ahead. During that delay,
use the documented Secret Manager restore/cancel behavior if the version was selected incorrectly;
after final destruction the payload is irrecoverable.

For an externally valid credential such as SMTP, disabling the Secret Manager version does not revoke
the credential at its issuer. Follow the SMTP runbook: create/rotate at the provider, add the new
Secret Manager version, deploy and verify health plus one controlled send, revoke the former
provider credential, and only then disable its Secret Manager version. Database owner and backup
passwords likewise require a coordinated PostgreSQL credential change before the old Secret Manager
version is disabled.

## Audit and cleanup

Query audit metadata without payloads:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud logging read \
  'protoPayload.serviceName="secretmanager.googleapis.com" AND protoPayload.resourceName:"/secrets/'"${SECRET_ID}"'"' \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --limit=20 \
  --format='table(timestamp,protoPayload.methodName,protoPayload.authenticationInfo.principalEmail)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: add/disable/enable/destroy metadata attributed to the named operator. Secret
Manager audit records do not include payloads.

Clear the remaining identifiers and close the private shell:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
unset MANAGEMENT_PROJECT_ID SECRET_ID VERSION_ID OLD_VERSION_ID CONFIRM_DESTROY
unset SECRET_VALUE SECRET_VALUE_CONFIRMATION
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

If shell tracing was ever enabled or a payload appeared on screen, treat the value as compromised:
rotate immediately, disable the exposed version after consumers move, revoke it at any external
issuer, and record the incident without reproducing the value.
