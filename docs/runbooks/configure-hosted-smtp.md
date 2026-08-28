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
[domain verification](https://docs.useplunk.com/guides/verifying-domains),
[tracking modes](https://docs.useplunk.com/guides/tracking),
[data-processing agreement](https://www.useplunk.com/dpa),
[privacy and retention](https://www.useplunk.com/privacy), and the
[AGPL-3.0 source](https://github.com/useplunk/plunk).

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
- the exact host, username, sender address, sender name, and sending domain shown by the provider;
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

Add the exact sending domain in the Plunk project. Copy the current DNS records from its dashboard;
do not copy example values from this runbook or another tenant.

The expected record classes are:

1. three DKIM CNAME records;
2. one SPF TXT policy;
3. one bounce-handling MX record;
4. a DMARC TXT policy, strongly recommended;
5. optional aligned MAIL FROM MX/TXT records when enabled.

A domain can have only one SPF policy. If one already exists, merge Plunk's dashboard-provided
mechanism into that single record; never publish a second `v=spf1` TXT value. Begin DMARC in monitor
mode only if the domain has not already adopted a stronger reviewed policy. Route aggregate reports
to a monitored mailbox, inspect them, then tighten deliberately. Do not weaken an existing DMARC
policy to complete this setup.

After DNS propagation, use the dashboard's recheck and independently inspect public DNS from a
private terminal. Substitute only non-secret domain and selector values:

```bash
SENDING_DOMAIN="$(./ops/prompt.sh 'Sending domain: ')"
DKIM_SELECTOR="$(./ops/prompt.sh 'First Plunk DKIM selector: ')"
[[ "$SENDING_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]
[[ "$DKIM_SELECTOR" =~ ^[a-z0-9_-]+$ ]]

dig +short TXT "$SENDING_DOMAIN"
dig +short CNAME "${DKIM_SELECTOR}._domainkey.${SENDING_DOMAIN}"
dig +short TXT "_dmarc.${SENDING_DOMAIN}"
```

Repeat the CNAME query for all three selectors and inspect the exact bounce/MAIL FROM names from the
dashboard. Expected result: Plunk reports every required record verified, exactly one SPF policy is
published, all DKIM selectors resolve, and the sending domain has a deliberate DMARC posture. DNS
can take up to 72 hours to propagate; wait rather than adding duplicates.

## 4. Capture the exact SMTP contract

Open the hosted project's SMTP credentials page from the official dashboard. Copy the exact
submission host, username, and password shown for this project. Plunk currently advertises TLS on
ports 465 and 587; Agora requires STARTTLS on `587`, not implicit TLS on `465` and never plaintext
port `25`.

Do not assume the username equals the sender address, project ID, or API-key name. Do not invent a
host from examples. If the hosted dashboard does not provide an authenticated SMTP credential, stop
and open an infrastructure issue; do not switch the application to the HTTP API inside an operator
procedure.

Validate only the non-payload fields locally:

```bash
SMTP_HOST="$(./ops/prompt.sh 'SMTP DNS host (without port): ')"
SMTP_USERNAME="$(./ops/prompt.sh 'SMTP username: ')"
SMTP_SENDER_EMAIL="$(./ops/prompt.sh 'SMTP sender email: ')"
SMTP_SENDER_NAME="$(./ops/prompt.sh 'SMTP sender display name: ')"

[[ "$SMTP_HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]
[[ "$SMTP_USERNAME" =~ ^[^[:space:]]{1,320}$ ]]
[[ "$SMTP_SENDER_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
[[ "${SMTP_SENDER_EMAIL##*@}" == "$SENDING_DOMAIN" ]]
[[ -n "$SMTP_SENDER_NAME" && "${#SMTP_SENDER_NAME}" -le 100 ]]
```

Use [Add or rotate a secret version](./secret-versions.md) to write the password through hidden
double entry to `production-authentication-smtp-sender-password`. Record only its numeric Secret
Manager version. Put `${SMTP_HOST}:587`, `SMTP_USERNAME`, the sender values, and the numeric password
version in the protected `RELEASE_CONFIG_JSON` exactly as described by
[Deploy and roll back production](./deploy-production.md#4-store-the-protected-non-payload-release-configuration).
Never store the password in that JSON document.

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
