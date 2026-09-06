# Configure Google Workspace SMTP relay

Use this runbook to send Authentication mail through the existing Google Workspace subscription.
The application submits messages over authenticated STARTTLS on port 587 and keeps its templates
in code. The operator manages relay access, domain authentication, credentials, and delivery logs.

## Operator inputs

Run local commands from the `a-novel/infra` checkout in a private zsh session. The four stable,
non-secret values are reviewed in `.envrc`:

| Variable            | Production value                       |
| ------------------- | -------------------------------------- |
| `SMTP_HOST`         | `smtp-relay.gmail.com`                 |
| `SMTP_USERNAME`     | `geoffroy.vincent@agorastoryverse.com` |
| `SMTP_SENDER_EMAIL` | `no-reply@agorastoryverse.com`         |
| `SMTP_SENDER_NAME`  | `Agora Storyverse`                     |

The sender appears in both the visible From header and SMTP envelope. Authentication uses the
separate Workspace login. Keep `no-reply` as an unregistered address; sending requires no additional
mailbox. The login account must have Gmail enabled and support app passwords.

```sh
. ./.envrc
```

## 1. Enable the relay and create an app password

In Google Admin, open **Apps → Google Workspace → Gmail → Routing → SMTP relay service** at the
top-level organization. Configure a rule named **Agora production SMTP**:

| Setting                                          | Value                            |
| ------------------------------------------------ | -------------------------------- |
| Allowed senders                                  | **Only addresses in my domains** |
| Only accept mail from the specified IP addresses | Unchecked                        |
| Require SMTP Authentication                      | Checked                          |
| Require TLS encryption                           | Checked                          |

Save the rule. Google says changes can take up to 24 hours. The
[relay documentation](https://knowledge.workspace.google.com/admin/gmail/advanced/route-outgoing-smtp-relay-messages-through-google)
explains sender authorization and account limits. Authentication uses Cloud Run's managed public
egress, whose IP can change; the current infrastructure has no static outbound IP.

Sign in as the account named by `SMTP_USERNAME`, enable 2-Step Verification, and open
[App passwords](https://myaccount.google.com/apppasswords). Create **Agora production SMTP** and
store the generated password in the password manager without display-grouping spaces. This is the
SMTP password. Keep it out of `.envrc`, command arguments, chat, and logs.

If app passwords are unavailable, check that account's security policy before changing the release
configuration. Account restrictions can prevent this authentication method. Changing the login
account's Google password revokes its app passwords; include SMTP credential replacement in that
account's password-change procedure. See [Google's app-password guidance](https://support.google.com/accounts/answer/185833).

## 2. Authenticate the sending domain

Keep the existing Workspace MX records, Google verification TXT records, and domain DMARC policy.
In the domain's single SPF TXT record, authorize Google with `include:_spf.google.com`. Retain other
active senders during the migration. When Google is the only sender, the policy can be
`v=spf1 include:_spf.google.com ~all`. Follow [Google's SPF setup](https://knowledge.workspace.google.com/admin/security/set-up-spf).

In **Google Admin → Apps → Google Workspace → Gmail → Authenticate email**, select the sending
domain. If an active Google DKIM key already exists, retain its selector. Otherwise generate a
2048-bit key with the available `google` selector, publish the exact TXT name and value shown by
Google, then click **Start authentication**. Confirm the status becomes **Authenticating email
with DKIM**. See [Google's DKIM setup](https://knowledge.workspace.google.com/admin/security/set-up-dkim).

Set this session-only input to the selector shown in Google Admin. The example uses Google's
default; replace it if the domain uses another selector:

```zsh
export SMTP_DKIM_SELECTOR='google'
```

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
[[ "$SMTP_HOST" == smtp-relay.gmail.com ]]
[[ "$SMTP_USERNAME" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
[[ "$SMTP_SENDER_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
[[ -n "$SMTP_SENDER_NAME" && "${#SMTP_SENDER_NAME}" -le 100 ]]
[[ "$SMTP_DKIM_SELECTOR" =~ ^[a-zA-Z0-9_-]+$ ]]
sender_domain="${SMTP_SENDER_EMAIL##*@}"
dmarc_report_email="dmarc-reports@${sender_domain}"
printf 'Sending identity: %s <%s>\n' "$SMTP_SENDER_NAME" "$SMTP_SENDER_EMAIL"
printf 'Expected DMARC report destination: %s\n' "$dmarc_report_email"
dig +short MX "$sender_domain"
dig +short TXT "$sender_domain"
dig +short TXT "${SMTP_DKIM_SELECTOR}._domainkey.${sender_domain}"
dig +short TXT "_dmarc.${sender_domain}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Check that the results contain Workspace MX records, exactly one SPF policy authorizing Google,
the selected DKIM key, and the existing DMARC policy. Confirm the DMARC report destination receives
mail through an existing mailbox or group; keep any other monitored destination already configured.
DNS publication alone does not prove that outgoing mail is signed: verify a delivered message in
step 5. Google documents up to 48 hours for DKIM activation.

## 3. Confirm capacity and delivery ownership

The relay uses the existing Workspace subscription without a separate per-message SMTP bill or
additional Google Cloud infrastructure. The subscription and any future paid mailbox remain outside
the [Google Cloud cost worksheet](../costs/production.md).

Google's published organization ceilings are 4.6 million recipient deliveries per 24 hours and
319,444 per 10 minutes. Actual account limits can be lower, particularly before paid billing
history exists. The documented per-user limits do not apply to an unregistered envelope sender;
organization limits and abuse controls still apply. Ask Workspace support for the tenant's actual
limits when forecast volume approaches its allowance.

Use **Google Admin → Reporting → Email Log Search** to investigate delivery by sender and time.
A nonexistent `no-reply` mailbox cannot receive bounce notifications; review these logs for failures
and avoid repeatedly sending to invalid addresses. The application does not import Plunk's bounce
or complaint suppression list. Before resuming sends, retain any existing suppression decisions
and apply them in the sending workflow. See [Email Log Search](https://knowledge.workspace.google.com/admin/support/troubleshooting/find-messages-with-email-log-search).

## 4. Capture the exact SMTP contract

The release configuration derives these runtime values from `.envrc`:

| Runtime field                            | Value                                                        |
| ---------------------------------------- | ------------------------------------------------------------ |
| `SMTP_ADDR`                              | `smtp-relay.gmail.com:587`                                   |
| `SMTP_SENDER_DOMAIN`                     | `smtp-relay.gmail.com`                                       |
| `SMTP_USERNAME`                          | The existing Workspace login from `.envrc`                   |
| `SMTP_SENDER_EMAIL` / `SMTP_SENDER_NAME` | The sender from `.envrc`                                     |
| `SMTP_SENDER_PASSWORD`                   | A numeric Secret Manager version containing the app password |

`SMTP_SENDER_DOMAIN` is the SMTP authentication hostname. The sender's email domain is configured
separately. The existing client enforces STARTTLS and verifies the server certificate.

After the configuration change is reviewed and merged, use a current `master` checkout and load
`.envrc`. Add the app password to the existing secret container using the
[secret-version procedure](./secret-versions.md):

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
./ops/add-secret-version.sh production-authentication-smtp-sender-password
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Paste the app password twice at the hidden prompts. Record the printed numeric version. The helper
stores the payload in the management project selected by `INFRA_MANAGEMENT_PROJECT_ID`.

For an existing environment, follow the [deployment runbook](./deploy-production.md): load its
operator context, verify repository state, and collect the existing foundation coordinates in
steps 1–2. In step 3, select the new SMTP version for `AUTH_SMTP_PASSWORD_VERSION` and retain all
other current secret versions. Step 4 rebuilds the protected `RELEASE_CONFIG_JSON`, including
`authentication.smtp` and `secret_versions.authentication_smtp_password`. Review the image manifest
in step 5, then dispatch the protected release in step 6 and verify it in step 7.

Updating `.envrc` or adding a secret version alone does not change a running service. Keep the
existing database credentials and initialization state for an SMTP-only migration. For first
launch, continue the [production setup](../setup-production.md) at its next incomplete step.

## 5. Validate without exposing the credential

1. Confirm the candidate `/v2/healthcheck` succeeds. The SMTP check authenticates and disconnects;
   it does not submit a message.
2. Through the normal application flow, request a signup or password-reset message to two
   controlled mailboxes at different providers, including one outside the Workspace domain.
3. Confirm each message arrives once and shows the configured sender name and email. Inspect the
   recipient's original headers for SPF, DKIM, and DMARC pass, with the sending domain aligned.
   Check that the message links reach the intended application origin.
4. Find both sends in Email Log Search. Keep only status, timestamp, and sanitized message
   identifiers as acceptance evidence; omit message contents, tokens, and SMTP transcripts.
5. If delivery or authentication fails, retain Plunk's credentials and DNS while correcting the
   relay rule, account password, or DKIM setup. An existing deployment can restore the prior receipt
   through the deployment runbook. A first launch has no successful receipt to restore.

## 6. Retire Plunk after the migration passes

Before removing the Plunk project, open **Settings → Domains**, select the production domain, and
save a private inventory of every DNS record it supplied: exact name, type, value, and TTL. Export
the corresponding DNS rows from the DNS provider. Plunk's
[domain guide](https://docs.useplunk.com/guides/verifying-domains) describes DKIM, SPF, and bounce
records; the project dashboard identifies this domain's exact values.

Keep Plunk available through the agreed rollback window. Allow already-submitted mail to finish
retrying before removing its signing and bounce records. After that window, remove only rows whose
complete name/type/value matches the Plunk inventory and which no other sender uses:

| DNS record                                         | Cleanup                                                                                                                                                           |
| -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Plunk DKIM CNAMEs                                  | Remove the selectors listed by this Plunk project, commonly three records with SES DKIM targets. Keep Google's DKIM selector and every other active sender's key. |
| SPF TXT on a shared domain                         | Remove only the mechanism added for Plunk, preserving one SPF policy and Google's include. A shared SES include stays while another active SES sender needs it.   |
| Plunk bounce / custom MAIL FROM MX and TXT         | Remove the exact dedicated subdomain records after pending deliveries have drained. Preserve the root Workspace MX records.                                       |
| Plunk verification or tracking records, if present | Remove records dedicated to this project. Keep a tracking hostname while previously sent links still depend on it, or provide a working replacement first.        |
| DMARC and Google verification TXT                  | Keep them; they authenticate or verify the domain independently of Plunk.                                                                                         |

Recheck SPF and send another application message after DNS cleanup. Revoke Plunk credentials,
remove unused Plunk secrets from other environments and password managers, and disable obsolete
Secret Manager versions once retained rollback receipts no longer reference them. Keep the shared
SMTP secret container and its active Google version.

Confirm no other application uses the project, retain any needed delivery/suppression records,
remove the domain and project from Plunk, and cancel any paid subscription or billing commitment.

## 7. Rotate Workspace credentials

Create another named app password, upload it as a new numeric version, update the protected release
configuration, deploy, and repeat delivery validation. Revoke the old app password and disable its
secret version only after the rollback window and receipt references have been retired. Repeat
this procedure before disabling or replacing the Workspace login account.
