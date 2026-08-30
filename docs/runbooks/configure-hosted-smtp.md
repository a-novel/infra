# Configure hosted Plunk SMTP

> First production run: step 4 configures the provider and captures its contract; step 6 performs
> delivery tests after Authentication is live.

Use this runbook to create the externally hosted SMTP dependency used by Authentication. Plunk is
an operator-owned SaaS account, not a Google Cloud resource and not an OpenTofu-managed
subscription. Infrastructure code consumes only its standard authenticated SMTP contract, so a
future provider change does not require an application rewrite.

Official references: [Plunk pricing](https://www.useplunk.com/pricing),
[hosted billing and limits](https://docs.useplunk.com/concepts/billing),
[SMTP feature](https://www.useplunk.com/features/smtp),
[API keys](https://docs.useplunk.com/guides/api-keys),
[domain verification](https://docs.useplunk.com/guides/verifying-domains),
[tracking modes](https://docs.useplunk.com/guides/tracking),
[data-processing agreement](https://www.useplunk.com/dpa),
[privacy and retention](https://www.useplunk.com/privacy), and the
[AGPL-3.0 source](https://github.com/useplunk/plunk).

## Operator context

Store the four non-secret runtime inputs reused by this runbook and production deployment in the
ignored `.envrc`. Use actual values, not placeholders. The SMTP password never belongs in this
file.

| Persistent variable | Exact value and authoritative source                                                                                                                                                                    |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SMTP_HOST`         | Open the [official Plunk SMTP page](https://www.useplunk.com/features/smtp) and copy its `host` field. Store the DNS hostname only, with no scheme or port.                                             |
| `SMTP_USERNAME`     | Copy the `username` field from that same official SMTP page. This is the login identifier, not the secret key used as the password.                                                                     |
| `SMTP_SENDER_EMAIL` | In the Plunk project, open **Settings → Domains** and choose an organization-controlled sender address whose domain exactly matches the verified production domain. Plunk does not choose this address. |
| `SMTP_SENDER_NAME`  | Choose the production display name shown to recipients, between 1 and 100 characters. Plunk does not supply this value.                                                                                 |

Add one `export NAME='actual value'` line per row to `.envrc`, then reload it:

```sh
${EDITOR:-vi} .envrc
. ./.envrc
```

`SMTP_DKIM_CNAME_RECORDS` is used only by this runbook, so keep it in the current shell. In the
Plunk project, open **Settings → Domains**, expand the production sender domain, and copy every DKIM
`CNAME` row. Preserve each full **Name** and **Value**, join each row as `name=value`, then join the
pairs with commas and no spaces. Set the resulting value directly, replacing the quoted example
with the value assembled from the dashboard:

```zsh
export SMTP_DKIM_CNAME_RECORDS='full-name-1=full-target-1,full-name-2=full-target-2'
```

Validate all five inputs:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
local sender_domain dkim_record record_name canonical_target
local -a dkim_records

[[ "$SMTP_HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]
[[ "$SMTP_USERNAME" =~ ^[^[:space:]]{1,320}$ ]]
[[ "$SMTP_SENDER_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
[[ -n "$SMTP_SENDER_NAME" && "${#SMTP_SENDER_NAME}" -le 100 ]]
[[ -n "$SMTP_DKIM_CNAME_RECORDS" && "$SMTP_DKIM_CNAME_RECORDS" != *[[:space:]]* ]]

sender_domain="${SMTP_SENDER_EMAIL##*@}"
[[ "$sender_domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]

dkim_records=("${(@s:,:)SMTP_DKIM_CNAME_RECORDS}")
(( ${#dkim_records[@]} >= 1 ))
for dkim_record in "${dkim_records[@]}"; do
  [[ "$dkim_record" == *=* ]]
  record_name="${dkim_record%%=*}"
  canonical_target="${dkim_record#*=}"
  [[ "$record_name" =~ ^[a-z0-9_]([a-z0-9_.-]*[a-z0-9])?\.?$ ]]
  [[ "$canonical_target" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?\.?$ ]]
done

printf 'Sending identity: %s <%s>\n' "$SMTP_SENDER_NAME" "$SMTP_SENDER_EMAIL"
printf 'SMTP endpoint: %s:587\n' "$SMTP_HOST"
printf 'DKIM CNAME inputs: %s\n' "${#dkim_records[@]}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

## Decision and boundary

Agora uses hosted Plunk at launch because its public source, standard SMTP interface, EU-hosted
control plane, usage pricing, and provider-managed delivery avoid an always-on mail stack. The
current paid offer has no recurring base fee, removes branding, and charges by usage; verify the
live offer before accepting it because external pricing and terms can change.

Self-hosting is deliberately deferred. The supported Plunk stack would add an application,
PostgreSQL, Redis, object storage, notifications, a public SMTP endpoint, TLS termination, delivery
provider credentials, abuse controls, upgrades, backups, and monitoring. Reconsider self-hosting
only when hosted cost, control, or compliance justifies owning those moving parts.

The application contract is:

- authenticated SMTP submission with mandatory STARTTLS on TCP `587`;
- the exact host and username shown by the provider, plus the operator-selected sender identity;
- one password stored only as a Secret Manager payload and referenced by numeric version;
- no Plunk SDK, API key, webhook, inbound mail, template, campaign, or workflow dependency.

Authentication can make managed public egress requests but receives no inbound Plunk access. Its
candidate health check opens the SMTP connection with a five-second timeout; it does not send mail.

## Authorization and stop conditions

The account owner performs this procedure in a private browser and terminal. Stop if any step asks
for a Google service-account key, a GitHub personal token, an application database credential, or a
credential pasted into repository code, an issue, a pull request, a DNS record, or a command-line
argument.

Before starting, choose:

- one organization-owned account identity and a second recovery owner;
- one controlled sending domain and sender mailbox;
- one monitored billing destination and a conservative monthly transactional-email cap;
- two controlled recipient mailboxes outside the sending domain at different representative mailbox
  providers, plus one operator-controlled address that deliberately rejects delivery.

Do not use a personal account that would disappear with one maintainer. Secure the account through
an upstream identity protected by phishing-resistant MFA when available, otherwise use a unique
password-manager credential. Store recovery information in the organization's private credential
system, not this repository.

## 1. Create the hosted project and cost guardrail

1. Open the official Plunk dashboard from `https://www.useplunk.com/` and create one production
   project. Record its human-readable name, owner, recovery owner, creation date, and billing owner
   in the private operations register.
2. Upgrade to the hosted pay-as-you-go offer. The free offer may add branding; the production
   requirement is no branding. This is the required external billing action—OpenTofu cannot create
   or pay for the subscription.
3. Under **Settings → Billing**, set the transactional category cap to the smallest amount that
   covers expected account, verification, and recovery emails. Leave campaign, workflow, inbound,
   and attachment use disabled or capped at zero when the dashboard supports it.
4. Confirm the monitored billing address receives provider notices. Record the current unit price,
   currency, cap, and review date privately. Do not hard-code a price into application state.
5. Confirm the dashboard counts authenticated SMTP submissions against the transactional category.
   If it does not, stop: a cap on an unrelated API category is not a cost guardrail for Agora.

Expected result: one paid hosted production project, no branding, a bounded transactional spend,
and no self-hosted Plunk resources.

## 2. Review privacy and data ownership

The owner must review the current DPA, privacy policy, terms, subprocessors, transfer mechanism,
retention, account-deletion behavior, and data-subject process before production use. Hosted Plunk
processes recipient addresses and message content; email delivery also necessarily exposes that
content to its delivery subprocessors.

Set **Settings → Tracking → Disabled**. Authentication emails do not need open pixels or rewritten
links. Verify the dashboard still reports tracking disabled after account or plan changes.

Record the accepted DPA/terms versions and review date privately. Do not place recipients, message
content, activity exports, screenshots containing credentials, or provider account identifiers in
this public repository. Before later migration, use the provider's documented access/portability
process, retain the minimum operational evidence needed for abuse and delivery investigations, then
delete the hosted project only after the replacement has passed a controlled send.

## 3. Verify the sending domain

Add the domain derived from `SMTP_SENDER_EMAIL` to the hosted project and apply every DNS row its
dashboard marks required. Derive the DMARC destination and record from the configured sender:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
local sender_domain dmarc_report_email

sender_domain="${SMTP_SENDER_EMAIL##*@}"
dmarc_report_email="dmarc-reports@${sender_domain}"

printf 'Google Workspace group: %s\n' "$dmarc_report_email"
printf 'DMARC TXT name: _dmarc.%s\n' "$sender_domain"
printf 'DMARC TXT value: v=DMARC1; p=none; rua=mailto:%s\n' "$dmarc_report_email"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Create the printed address as a private, monitored Google Workspace group. In Google Admin, open
**Directory → Groups**, create the group, allow external senders, add at least one monitored member,
then prove delivery from an address outside the Workspace domain. Publish the printed DMARC TXT row
after that test succeeds.

Keep the existing Google Workspace MX records. A domain can publish only one SPF policy. If Plunk's
dashboard supplies an SPF mechanism, merge that exact mechanism into the existing policy. Add a
bounce or MAIL FROM record only when the dashboard supplies its exact name and value.

After DNS propagation, use the dashboard recheck and validate public DNS separately:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
local sender_domain dmarc_report_email dkim_record record_name expected_target
local resolved_target published_dmarc spf_records
local -a dkim_records

sender_domain="${SMTP_SENDER_EMAIL##*@}"
dmarc_report_email="dmarc-reports@${sender_domain}"
dkim_records=("${(@s:,:)SMTP_DKIM_CNAME_RECORDS}")

for dkim_record in "${dkim_records[@]}"; do
  record_name="${dkim_record%%=*}"
  expected_target="${dkim_record#*=}"
  record_name="${record_name%.}"
  expected_target="${expected_target%.}."
  resolved_target="$(dig +short CNAME "$record_name")"
  [[ -n "$resolved_target" && "$resolved_target" != *$'\n'* ]]
  resolved_target="${resolved_target%.}."
  [[ "${resolved_target:l}" == "${expected_target:l}" ]]
  printf 'DKIM %s -> %s\n' "$record_name" "$resolved_target"
done

spf_records="$(dig +short TXT "$sender_domain" | grep -i '^"v=spf1')"
[[ -n "$spf_records" ]]
[[ "$(printf '%s\n' "$spf_records" | wc -l | tr -d ' ')" == 1 ]]
printf 'SPF %s\n' "$spf_records"

published_dmarc="$(dig +short TXT "_dmarc.${sender_domain}" | tr -d '"')"
[[ "$published_dmarc" == *'v=DMARC1;'* ]]
[[ "$published_dmarc" == *"rua=mailto:${dmarc_report_email}"* ]]
printf 'DMARC %s\n' "$published_dmarc"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected result: every configured DKIM pair, the single SPF policy, and DMARC print successfully,
and the provider reports every required row verified. DNS can take up to 72 hours to propagate;
wait before retrying the same checks.

## 4. Capture the exact SMTP contract

Confirm `SMTP_HOST` and `SMTP_USERNAME` still match the `host` and `username` fields on the
[official SMTP page](https://www.useplunk.com/features/smtp). In the Plunk project, open
[**Settings → API Keys**](https://docs.useplunk.com/guides/api-keys) and identify the **Secret key**
with the `sk_` prefix. That secret key is the SMTP password; the `pk_` public key is not. Plunk
advertises TLS on ports 465 and 587; Agora requires
STARTTLS on `587`, not implicit TLS on `465` and never plaintext port `25`.

Do not assign the secret key to a shell variable. If the dashboard does not provide an `sk_` secret
key, stop and open an infrastructure issue.

Validate the non-secret contract loaded from `.envrc`:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
local sender_domain

[[ "$SMTP_HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]
[[ "$SMTP_USERNAME" =~ ^[^[:space:]]{1,320}$ ]]
[[ "$SMTP_SENDER_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
[[ -n "$SMTP_SENDER_NAME" && "${#SMTP_SENDER_NAME}" -le 100 ]]
sender_domain="${SMTP_SENDER_EMAIL##*@}"
[[ "$sender_domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]

printf 'SMTP endpoint: %s:587\n' "$SMTP_HOST"
printf 'Sending domain: %s\n' "$sender_domain"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Use [Add or rotate a secret version](./secret-versions.md) to write the password through hidden
double entry to `production-authentication-smtp-sender-password`. Record only its numeric Secret
Manager version. Stop here; do not construct or upload `RELEASE_CONFIG_JSON` from this runbook.

When following [Deploy and roll back production](./deploy-production.md), run its sections in order:

1. [Select and verify exact secret versions](./deploy-production.md#3-select-and-verify-exact-secret-versions)
   assigns the enabled numeric SMTP version to `AUTH_SMTP_PASSWORD_VERSION` without reading its
   payload.
2. [Store the protected non-payload release configuration](./deploy-production.md#4-store-the-protected-non-payload-release-configuration)
   reads the four non-secret SMTP values from `.envrc`, builds the complete temporary JSON, and
   uploads it as the protected GitHub environment secret.

Run both command blocks without manually editing the JSON. Only the numeric version enters the
document; the SMTP password never does.

## 5. Validate without exposing the credential

Do not test with `openssl`, `swaks`, or a command-line SMTP client: those paths commonly place the
credential in arguments, debug output, or transcripts. Let the protected Authentication release
consume the exact Secret Manager version.

1. Keep `PRODUCTION_RELEASES_ENABLED=false` until all release prerequisites pass.
2. Run the protected first release from the reviewed manifest.
3. Confirm the candidate `/v2/healthcheck` succeeds. A failure must report only the dependency name,
   never the SMTP response body or credential.
4. Through the normal application flow, send one non-sensitive transactional test to the selected
   mailbox at each representative provider. Record request-to-delivery latency without recording a
   recipient address or message body.
5. Confirm exactly one message arrives at each mailbox, has no Plunk branding or tracking
   redirect/pixel, and its headers report SPF, DKIM, and DMARC alignment. Confirm Plunk records both
   deliveries without an unexpected bounce or complaint.
6. Send one non-sensitive message through the same application flow to the operator-controlled
   address that is configured to reject delivery. Do not guess a random nonexistent address and do
   not deliberately create a spam complaint. Confirm the Plunk activity feed records exactly one
   `email.bounce` event and its hard/soft classification. This verifies the bounce-feedback MX path
   without adding a webhook or runtime component.
7. Test the cap with bounded usage. Note the current transactional count, temporarily set the cap to
   the smallest dashboard-supported value above that count, and send at most two additional
   operator-controlled messages: one to reach the cap and one to prove the next submission is
   blocked. Confirm the provider notice arrives, restore the reviewed production cap, and send one
   final successful message. If the dashboard cannot test a cap this way, record the limitation and
   keep production disabled until the provider documents a safe equivalent; never send a batch to
   discover the limit.

Do not paste full headers publicly: they can carry recipient, provider, and tenant identifiers.
Record pass/fail, time, sender domain, recipient domains, delivery latency, bounce classification,
cap-test result, and the deployed receipt privately.

## Rotation, incident, and exit procedure

For routine rotation, create a new hosted SMTP credential when the provider supports independent
credentials, add it as a new Secret Manager version, deploy the new numeric version, pass health and
one controlled send, then revoke the old provider credential. Only afterward disable the old Secret
Manager version. If Plunk rotates in place, schedule a release window: add the new secret version
immediately, deploy, verify, and revoke any surviving prior token.

For suspected compromise, stop application sending at the provider cap first, preserve provider and
Google audit evidence, rotate/revoke the hosted credential, deploy the new numeric version, and
review recipients, bounces, complaints, and charges. Never print or compare credential payloads.

For provider exit, configure another authenticated STARTTLS SMTP service behind the same five
fields, verify its domain and one controlled send, deploy it, then revoke Plunk. Export or request
only the records required by the retention/legal decision and delete the Plunk project after the
replacement receipt is durable. Self-hosting remains one possible later provider, not a launch
dependency.
