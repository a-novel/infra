# Configure Google Workspace SMTP relay

Use the existing Workspace subscription for Authentication mail over authenticated STARTTLS on
port 587. Already deployed with Workspace? Load the operator context, then go straight to step 5;
do not recreate credentials or repeat setup.

## Operator context

Run from a current `a-novel/infra` checkout in a private zsh session. Stop on any failed command.
Required tools: `gcloud`, `gh`, `jq`, `curl`, `dig`, `openssl`, GNU `date`, and `timeout`.

```sh
. ./.envrc
./ops/verify-operator-env.sh --github
```

Keep these long-term, non-secret inputs in the reviewed `.envrc`; change them through a PR.

| Variable            | Value / source                                                                         |
| ------------------- | -------------------------------------------------------------------------------------- |
| `SMTP_HOST`         | `smtp-relay.gmail.com` for Workspace relay                                             |
| `SMTP_USERNAME`     | Full login address of the Gmail-enabled Workspace account used for SMTP authentication |
| `SMTP_SENDER_EMAIL` | Intended From address in your Workspace domain; it need not be a mailbox               |
| `SMTP_SENDER_NAME`  | Display name recipients should see                                                     |
| `PLATFORM_AUTH_URL` | Web client's HTTPS origin, without a trailing slash; not the Authentication API URL    |

Print the existing values and derive the DNS names:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
: "${SMTP_HOST:?Load .envrc first}" "${SMTP_USERNAME:?Set the Workspace login in .envrc}" "${SMTP_SENDER_EMAIL:?Set the sender in .envrc}" "${SMTP_SENDER_NAME:?Set the display name in .envrc}"
[[ "$SMTP_HOST" == smtp-relay.gmail.com ]]
[[ "$SMTP_SENDER_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
sender_domain="${SMTP_SENDER_EMAIL##*@}"
dmarc_report_email="dmarc-reports@${sender_domain}"
printf 'Relay: %s:587\nLogin: %s\nFrom: %s <%s>\nSending domain: %s\nWeb client: %s\n' "$SMTP_HOST" "$SMTP_USERNAME" "$SMTP_SENDER_NAME" "$SMTP_SENDER_EMAIL" "$sender_domain" "$PLATFORM_AUTH_URL"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Use the foundation-declared human secret operator for step 4. It already has the secret-specific
version-management permissions described in [Secret versions](./secret-versions.md); do not grant
payload access to release automation. Step 5 needs Cloud Run and log read access, not job execution.

### Temporary read access, only if needed

If step 5 reports `PERMISSION_DENIED`, a project IAM administrator can run this block in the
operator's session. First run `gcloud config get-value account` and confirm it is the intended
operator. It adds separate, one-hour
read-only grants; existing grants are not changed. Allow a few minutes for propagation.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
SMTP_AUDIT_MEMBER="${SMTP_AUDIT_MEMBER:-user:$(gcloud config get-value account 2>/dev/null)}"
[[ "$SMTP_AUDIT_MEMBER" =~ ^user:[^[:space:]@]+@[^[:space:]@]+$ ]]
SMTP_AUDIT_EXPIRY="$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)"
SMTP_AUDIT_CONDITION="expression=request.time < timestamp('${SMTP_AUDIT_EXPIRY}'),title=smtp-read-check"
printf 'Read access for %s until %s\n' "$SMTP_AUDIT_MEMBER" "$SMTP_AUDIT_EXPIRY"
for role in roles/run.viewer roles/logging.viewer; do
gcloud projects add-iam-policy-binding "$INFRA_WORKLOAD_PROJECT_ID" --member="$SMTP_AUDIT_MEMBER" --role="$role" --condition="$SMTP_AUDIT_CONDITION" --format=none
done
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The administrator needs `resourcemanager.projects.setIamPolicy`. If using a different admin login,
set `SMTP_AUDIT_MEMBER` to the operator's `user:` principal instead of deriving the admin's account.
Set the member before the block; an explicit value is preserved. These are [time-limited IAM grants](https://cloud.google.com/iam/docs/conditions-overview), not Workspace permissions.

## 1. Enable the relay and create an app password

This is a Workspace Admin setting, not a `gcloud` resource. In
[Google Admin](https://admin.google.com/), open **Apps → Google Workspace → Gmail → Routing → SMTP
relay service** at the top-level organization. Reuse the existing rule, or create **Agora production SMTP**:

| Setting                                          | Value                                            |
| ------------------------------------------------ | ------------------------------------------------ |
| Allowed senders                                  | **Only addresses in my domains**                 |
| Only accept mail from the specified IP addresses | Unchecked: Cloud Run's managed egress IP changes |
| Require SMTP Authentication                      | Checked                                          |
| Require TLS encryption                           | Checked                                          |

Save; [Google allows up to 24 hours for propagation](https://knowledge.workspace.google.com/admin/gmail/advanced/route-outgoing-smtp-relay-messages-through-google).
Do not add a static IP, NAT, or an unauthenticated relay rule.

Sign in as `SMTP_USERNAME`. With 2-Step Verification enabled, open
[App passwords](https://myaccount.google.com/apppasswords), create **Agora production SMTP**, and
save the generated value in your password manager without its display-grouping spaces. This is the
SMTP password, **not** the normal Google account password. Reuse a working app password on subsequent
runs. If account policy hides this option, stop and ask the Workspace administrator; do not weaken
2-Step Verification. [Changing the Google account password revokes app passwords](https://support.google.com/accounts/answer/185833).

Never put the password in `.envrc`, command arguments, chat, or logs. Upload it only at step 4's
hidden prompts. There is no app-password creation command in this guide.

## 2. Authenticate the sending domain

Inspect the current public DNS and identify its authoritative host:

```sh
dig +short NS "$sender_domain"
dig +short MX "$sender_domain"
dig +short TXT "$sender_domain"
dig +short TXT "_dmarc.${sender_domain}"
```

Preserve Workspace MX and Google verification records. Keep **one** SPF TXT policy authorizing
`include:_spf.google.com`; if Google is the only sender it can be `v=spf1 include:_spf.google.com ~all`.
Do not overwrite other active senders or downgrade an existing stricter DMARC policy.
[SPF reference](https://knowledge.workspace.google.com/admin/security/set-up-spf).

For DKIM, open **Google Admin → Apps → Google Workspace → Gmail → Authenticate email**, select
`sender_domain`, and reuse the active key. If absent, generate a 2048-bit key. Publish the exact
**DNS Host name (TXT record name)** and **TXT record value** shown there at the DNS host above,
then select **Start authentication**. Public DKIM values are safe DNS data; never copy a private key.
DNS writes are provider-specific; `gcloud dns` must not be used against this repository's private VPC zone.
[Google's DKIM instructions](https://knowledge.workspace.google.com/admin/security/set-up-dkim).

Set session-only `SMTP_DKIM_SELECTOR` to the part before `._domainkey` in that Host name. Google's
default is `google`; run this assignment only if it matches the displayed name, otherwise assign
that displayed selector instead:

```zsh
export SMTP_DKIM_SELECTOR='google'
```

```sh
dig +short TXT "${SMTP_DKIM_SELECTOR:?Set the selector from Google Admin}._domainkey.${sender_domain}"
```

Expect a non-empty DKIM public key. Admin status must become **Authenticating email with DKIM**;
publication alone does not prove signing. Activation can take up to 48 hours.

If DMARC is missing, first ensure the following report address is a monitored mailbox/group that
accepts external mail. Publish the printed TXT only after testing that destination; keep an existing
monitored DMARC destination if different.

```sh
printf 'Report address: %s\nTXT name: _dmarc.%s\nTXT value: v=DMARC1; p=none; rua=mailto:%s\n' "$dmarc_report_email" "$sender_domain" "$dmarc_report_email"
```

## 3. Check DNS and TLS without a password

```sh
dig +short A "$SMTP_HOST"
dig +short AAAA "$SMTP_HOST"
timeout 20 openssl s_client -starttls smtp -connect "${SMTP_HOST}:587" -servername "$SMTP_HOST" -verify_hostname "$SMTP_HOST" -verify_return_error -brief </dev/null
```

Expect successful certificate verification. Do not use `-k`, disable TLS verification, or supply a
password to this diagnostic. A local network may block port 587; this test covers your workstation,
while step 5 tests the deployed application's connection.

Workspace subscription and abuse limits still apply; do not exhaust a quota or send to invalid
addresses to test them. See [relay limits](https://knowledge.workspace.google.com/admin/gmail/advanced/route-outgoing-smtp-relay-messages-through-google).
A sender without a mailbox cannot receive bounce notifications: use step 5's delivery investigation.

## 4. Capture the exact SMTP contract

For initial provisioning, return to [setup step 5](../setup-production.md#5-create-the-initial-payload-versions)
to upload all seven initial secrets once. The commands below are for an existing environment.

List version metadata before adding anything, especially after a previous interrupted upload:

```sh
gcloud secrets versions list production-authentication-smtp-sender-password --project="$INFRA_MANAGEMENT_PROJECT_ID" --format='table(name.basename(),state,createTime)'
```

If the correct app password already has an enabled version, reuse it. Otherwise upload it once:

```sh
./ops/add-secret-version.sh production-authentication-smtp-sender-password
```

Paste it twice at the hidden prompts and record the printed numeric version. No payload is printed
or written to a local file. Set session variable `AUTH_SMTP_PASSWORD_VERSION` to that exact integer;
never infer it from `latest`, and do not disable older versions referenced by rollback receipts.

Verify that selection:

```sh
gcloud secrets versions describe "${AUTH_SMTP_PASSWORD_VERSION:?Set the numeric version printed by the upload or selected from the metadata list}" --secret=production-authentication-smtp-sender-password --project="$INFRA_MANAGEMENT_PROJECT_ID" --format='yaml(name,state)'
```

Require `ENABLED`. The [deployment runbook](./deploy-production.md) is the single configuration writer:

| Existing deployment | Action                                                              |
| ------------------- | ------------------------------------------------------------------- |
| Steps 1–2           | Load its operator context and collect foundation coordinates        |
| Step 3              | Select this SMTP version; retain the other deployed secret versions |
| Step 4              | Rebuild and store `RELEASE_CONFIG_JSON` with the selected values    |
| Steps 5–7           | Review the image family, deploy, and verify the successful receipt  |

That configuration sets `authentication.smtp.address` to `${SMTP_HOST}:587`, `sender_domain` to
`SMTP_HOST` (the TLS/authentication server hostname, **not** the sending domain), the login and sender
from `.envrc`, and `secret_versions.authentication_smtp_password` to the selected integer. The
runtime resolves the password from Secret Manager. Authentication v2.7.0+ supplies the correct EHLO
domain; keep the reviewed current image family.

Changing `.envrc`, uploading a version, or updating GitHub configuration does not change the running
service until deployment succeeds. For initial provisioning, resume [production setup](../setup-production.md)
at its next incomplete step. Do not rerun database initialization for an SMTP change.

## 5. Validate without exposing the credential

### Discover the deployed service and check health

After a successful release, reload `.envrc` (deployment setup may unset `SMTP_USERNAME`) and run:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
. ./.envrc
AUTH_URL="$(gcloud run services describe agora-authentication-rest --project="$INFRA_WORKLOAD_PROJECT_ID" --region="$INFRA_REGION" --format='value(status.url)')"
[[ "$AUTH_URL" =~ ^https://[a-z0-9.-]+\.run\.app$ ]]
curl -q --silent --show-error --fail --connect-timeout 10 --max-time 60 "${AUTH_URL}/v2/healthcheck" | jq -e 'length > 0 and all(.[]; .status == "up")'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expect `true`. SMTP health authenticates and disconnects; it does **not** send mail.

### Send one real application message

Set session-only `SMTP_TEST_EMAIL` to an inbox address you control, copied from that mail account's
address/profile page. Use `export SMTP_TEST_EMAIL='your actual inbox address'` with that value, not
the literal description. It must **not** already be registered in Authentication; an unused alias
is fine if your mailbox provider supports it. Do not put test recipients in `.envrc`.

Run the block once for that address, then set `SMTP_TEST_EMAIL` to a second controlled inbox at a
different provider (at least one outside Workspace) and run it once more. These requests create
expiring signup codes, **not accounts**. Do not redeem the links just to validate mail delivery.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
local token payload code
: "${AUTH_URL:?Run service discovery first}" "${SMTP_TEST_EMAIL:?Set a controlled, unregistered inbox address in this session}"
[[ "$AUTH_URL" =~ ^https://[a-z0-9.-]+\.run\.app$ ]]
[[ "$SMTP_TEST_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
SMTP_TEST_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
token="$(curl -q --silent --show-error --fail --connect-timeout 10 --max-time 60 --request PUT "${AUTH_URL}/v2/session/anon" | jq -er '.accessToken | select(type == "string" and length > 0) | select(test("[\\r\\n]") | not)')"
payload="$(jq -nc --arg email "$SMTP_TEST_EMAIL" '{email: $email, lang: "en"}')"
code="$(printf 'Authorization: Bearer %s\n' "$token" | curl -q --silent --show-error --fail --connect-timeout 10 --max-time 60 --request PUT --header @- --header 'Content-Type: application/json' --data "$payload" --output /dev/null --write-out '%{http_code}' "${AUTH_URL}/v2/short-code/register")"
[[ "$code" == 202 ]] || { printf 'STOP: expected HTTP 202, received %s.\n' "$code" >&2; return 1; }
printf 'Request accepted at %s; verify inbox delivery next.\n' "$SMTP_TEST_STARTED_AT"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The anonymous token stays in a local shell variable and reaches `curl` through stdin, never an
argument, exported variable, or file. Keep tracing and session recording off. Do not add verbose
curl output, redirects, or automatic retries. If a request times out, check the inbox/logs before
resubmitting; another signup request replaces the previous code.

`202` means **accepted**, not delivered. Already-registered addresses also receive `202` but no
signup email. The [Authentication API contract](https://github.com/a-novel/service-authentication/blob/master/openapi.yaml)
documents this behavior. For an existing account's password-reset test, use the same block with
`/v2/short-code/update-password` instead; never reset another person's account.

### Verify receipt and investigate failures

For each inbox, check one message arrived, the From values match `.envrc`, and the receiver reports
SPF, DKIM, and DMARC passing with the sending domain aligned. In Gmail: **More → Show original**.
The signup link must start with `${PLATFORM_AUTH_URL}/ext/account/create` (reset uses
`/ext/password/reset`); inspect it privately, without posting its query string or code.

Read bounded delivery-event metadata after each test (no message bodies or exception details):

```sh
gcloud logging read "resource.type=cloud_run_revision AND resource.labels.service_name=agora-authentication-rest AND timestamp>=\"${SMTP_TEST_STARTED_AT:?Run the mail test first}\" AND (jsonPayload.Body.Value=\"mail delivered\" OR jsonPayload.Body.Value=\"mail delivery failed\")" --project="$INFRA_WORKLOAD_PROJECT_ID" --order=asc --limit=20 --format='table(timestamp,jsonPayload.Body.Value,resource.labels.revision_name)'
```

Allow log ingestion to catch up before repeating that read. Application success means the relay
accepted the message, not that it reached the inbox. No rows is **not** a pass. For the final delivery
status, use **Google Admin → Reporting → Email Log Search**, filtering by `SMTP_SENDER_EMAIL`, the
test recipient, and the printed test time. This Workspace log is separate from Cloud Logging;
[Email Log Search](https://knowledge.workspace.google.com/admin/support/troubleshooting/find-messages-with-email-log-search)
is the fallback when inbox delivery fails. Preserve timestamp, status, and a sanitized message ID
only; never paste mail bodies, reset links, tokens, or SMTP transcripts.

If validation fails, stop rollout/credential retirement and correct the current Workspace setup.
Only roll back to a receipt whose credentials and relay configuration still work.

After the deployment runbook's log audit, if you added the temporary grants above, remove
**those exact conditional bindings** in the same session; do not remove pre-existing unconditional roles. An administrator must run this cleanup:

```sh
gcloud projects remove-iam-policy-binding "$INFRA_WORKLOAD_PROJECT_ID" --member="${SMTP_AUDIT_MEMBER:?Use the same session as the grant}" --role=roles/run.viewer --condition="${SMTP_AUDIT_CONDITION:?Use the same condition as the grant}" --format=none
gcloud projects remove-iam-policy-binding "$INFRA_WORKLOAD_PROJECT_ID" --member="${SMTP_AUDIT_MEMBER:?Use the same session as the grant}" --role=roles/logging.viewer --condition="${SMTP_AUDIT_CONDITION:?Use the same condition as the grant}" --format=none
unset SMTP_TEST_EMAIL SMTP_TEST_STARTED_AT SMTP_AUDIT_MEMBER SMTP_AUDIT_EXPIRY SMTP_AUDIT_CONDITION
```

If the session is lost, access still expires after one hour; ask the administrator to remove the
expired `smtp-read-check` bindings later. Then resume the deployment runbook's log audit or the
next incomplete setup step.

## 6. Rotate Workspace credentials

Repeat steps 1 and 4 with a new named app password, deploy, and repeat step 5. Keep the previous
app password and Secret Manager version available while any retained rollback receipt uses them.
Only after that window, revoke the old app password in the account's App passwords page and disable
its exact old version using [Secret versions](./secret-versions.md#rotate-through-a-controlled-rollout).
Do not delete the shared secret container or rotate database credentials for this operation.
