# Secrets

This runbook is about secret values. OpenTofu manages the secret containers, in the management
project. Humans add their values with `gcloud`, so the values never reach state, plans or Git. Each
workload reads the numeric version its root's `terraform.tfvars` pins, so a new value takes effect
only once a pull request pins it.

## Rotate a secret

This is the general procedure. The database password, the waitlist secret and the pgBackRest
certificates rotate differently, because something besides the service reads them.
`production-json-keys-app-master-key` has no rotation procedure. It encrypts the signing keys JSON
Keys stores, and a new value cannot decrypt them.

1. **Add a version.** Paste the value at the prompt, which does not echo it.

   ```bash
   SECRET="production-<service>-<name>"
   read -rs VALUE
   printf '%s' "$VALUE" | gcloud secrets versions add "$SECRET" --project=a-novel-management-prod --data-file=-
   unset VALUE
   gcloud secrets versions list "$SECRET" --project=a-novel-management-prod --limit=3
   ```

   | Secret              | Format                                                    |
   | ------------------- | --------------------------------------------------------- |
   | `*-app-password`    | 32–128 characters, `[A-Za-z0-9_-]`, different per service |
   | `*-app-master-key`  | 64 hexadecimal characters                                 |
   | `*-waitlist-secret` | at least 32 characters                                    |
   | `*-openai-api-key`  | an OpenAI project key restricted to the Responses API     |

2. **Pin the new number** in `secret_versions` in the service root, in a pull request, and merge it.
   The deploy rolls out a new revision that reads it.
3. **Disable the old version** once the deploy is healthy:

   ```bash
   OLD="<old version number>"
   gcloud secrets versions disable "$OLD" --secret="$SECRET" --project=a-novel-management-prod
   ```

4. **Destroy it** only when you are sure it is no longer needed. Destruction becomes final 30 days
   later.

   ```bash
   gcloud secrets versions destroy "$OLD" --secret="$SECRET" --project=a-novel-management-prod
   ```

Disabling a version does not revoke the credential where it was issued. For a leak, also revoke it
there, such as in the Google account or the database role.

### Database password

The database host sets the application role's password at boot, from foundation's
`database_releases.<service>.app_password_version`. The service reads the same secret through
`secret_versions.app-password` in its root.

1. Add the version.
2. In **one** pull request, bump both values.
3. Merge it as a [database host change](database.md#change-a-database-host), during a planned
   downtime. The deploy gives the service the new version, then the rollout restarts the host, which
   sets it. The services refuse work during the downtime, so nothing fails in between.

## SMTP (Google Workspace relay)

Authentication sends mail through the Google Workspace SMTP relay on port 587, with STARTTLS and no
credential: the relay admits it by the production NAT address. The authentication root's `smtp`
input names the relay and the sender.

The relay rule is in Google Admin under **Apps → Google Workspace → Gmail → Routing → SMTP relay
service**. Its settings are "only addresses in my domains", "only accept mail from the specified IP
addresses" with the NAT addresses alone, and "require TLS", without SMTP authentication. The
addresses are foundation's `cluster_nat_address` and, until the old network retires, `nat_address`.

Health reporting `client:smtp` up proves only that the relay answers over TLS. Only a real email
proves that the relay accepts the service's address, so send one after any change to the rule or
to the [NAT address](../architecture.md#network).

## Waitlist

To turn it on:

1. Add a version of `production-authentication-waitlist-secret`.
2. In the authentication root, set `waitlist_url` and `secret_versions.waitlist-secret`, and merge.

The Apps Script behind the waitlist must use the same secret, so update both together. Requests
fail while they differ. To turn the waitlist off, remove both settings.

## GitHub dispatch tokens

GitHub starts scheduled workflows hours late. The `github-dispatch` Cloud Workflow therefore
dispatches the timed workflows on time, in the repositories that `github_dispatch_schedules` lists
in `bootstrap/github-dispatch.tf`. It uses one fine-grained personal access token per org. Create
each one in the browser, in
[Fine-grained tokens](https://github.com/settings/personal-access-tokens/new):

- **Resource owner:** the org, `a-novel` or `a-novel-kit`. An org that reviews tokens asks an owner
  to approve it.
- **Repository access:** only the org's repositories that `github_dispatch_schedules` lists, its
  `.github` repository included, and for `a-novel`, `infra`, whose sweep and drift check it starts.
- **Permissions:** Actions, read and write. Nothing else.
- **Expiration:** the longest the org allows. The `.github` repository's daily `token-expiry`
  workflow posts to Discord before it lapses.

Add each one as a version of `production-github-dispatch-<org>`, as in
[Rotate a secret](#rotate-a-secret), and pin it in bootstrap's `github_dispatch_token_versions`. The
next dispatch after the deploy reads it. The token can start, rerun, cancel and delete workflow runs
in those repositories. For a leak, revoke it on GitHub as well as disabling its version.

## Sentry configuration tokens

The Sentry root reads one Sentry token per CI identity. Create each one in Sentry, under
**Settings → Developer Settings → Custom Integrations → Create New Integration → Internal
Integration**, without a webhook:

| Secret                           | Integration name | Permissions                                                |
| -------------------------------- | ---------------- | ---------------------------------------------------------- |
| `production-sentry-plan-token`   | `infra-plan`     | Read on Project, Team, Organization and Alerts             |
| `production-sentry-deploy-token` | `infra-deploy`   | Write on Project and Alerts, Read on Team and Organization |

Copy each integration's token, add it as a version of its secret, as in
[Rotate a secret](#rotate-a-secret), and pin it in the Sentry root's `token_versions`. Pull requests
and the drift check read the plan token, and deploys the deploy token. An internal integration token
never expires. For a leak, delete the integration's token in Sentry as well as disabling its
version.

## Grafana configuration tokens

The Grafana root reads one token per CI identity, from a service account of the production stack.
Create each one in the stack's Grafana, under **Administration → Users and access → Service
accounts**:

| Secret                            | Service account | Role   |
| --------------------------------- | --------------- | ------ |
| `production-grafana-plan-token`   | `infra-plan`    | Viewer |
| `production-grafana-deploy-token` | `infra-deploy`  | Admin  |

The deploy account is an Admin because Grafana caches each identity's folder permissions: an
Editor that creates a folder cannot read it back for a moment, which leaves the folder tainted.
Give neither account a provisioning role. The provisioning API accepts the alerting permissions of
the basic roles, and **Read via Provisioning API + Export Secrets** hands the Discord contact
point's webhook to pull-request code.

Add each token as a version of its secret, as in [Rotate a secret](#rotate-a-secret), and pin it in
the Grafana root's `token_versions`. Pull requests and the drift check read the plan token as
`infra-plan`, and deploys the deploy token as `infra-grafana`. Create the tokens without an expiry.
For a leak, delete the token in Grafana as well as disabling its version.

Grafana's Discord contact point is created by hand in the same stack, so its webhook never reaches
state. Its title and message call the Grafana root's templates, as
[Grafana alerts](alerts.md#grafana-alerts) shows.

## Grafana Cloud tokens

Frontend Observability's API takes a Grafana Cloud access policy token, which no stack service
account replaces, so bootstrap holds one for each CI identity of the Grafana root. Create each
policy in the Cloud Portal, under **Security → Access policies**, with the production stack as its
realm, then a token without an expiry:

| Secret                                  | Access policy  | Scopes                                                                                                        |
| --------------------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------- |
| `production-grafana-cloud-plan-token`   | `infra-plan`   | `stacks:read`, `frontend-observability:read`                                                                  |
| `production-grafana-cloud-deploy-token` | `infra-deploy` | `stacks:read`, `frontend-observability:read`, `frontend-observability:write`, `frontend-observability:delete` |

Add each token as a version of its secret, as in [Rotate a secret](#rotate-a-secret). Pull requests
and the drift check read the plan token as `infra-plan`, and deploys the deploy token as
`infra-grafana`. For a leak, delete the token in the Cloud Portal as well as disabling its version.

## GitHub root keys

The GitHub root reads one GitHub App key per organization and CI identity. Core creates each
organization's Plan App and Deploy App by hand, with the permissions a-novel/.github#535 lists.
Generate a private key under the App's **Private keys** settings, add the downloaded file as a
version of its secret, then delete the file:

```bash
SECRET="production-github-<plan|deploy>-key-<org>"
KEY_FILE="<path to the downloaded .pem>"
gcloud secrets versions add "$SECRET" --project=a-novel-management-prod --data-file="$KEY_FILE"
```

| Secret                               | App                     | Read by                                                                 |
| ------------------------------------ | ----------------------- | ----------------------------------------------------------------------- |
| `production-github-plan-key-<org>`   | the Plan App, read-only | `infra-plan`, for pull requests                                         |
| `production-github-deploy-key-<org>` | the Deploy App          | `infra-github` for deploys and the sweep, `infra-drift` for drift plans |

For a leak, delete the key in the App's settings as well as disabling its version.

## Governance secrets

`production-github-governance-<org>-<name>` holds a privileged key that each of the organization's
repositories receives in its `governance` environment when its workflows name it. The secret's
`contract` annotation is its name in GitHub: `AGENT_BOT_PRIVATE_KEY`, `DEPENDENCY_BOT_PRIVATE_KEY`
or `BWS_READ_TOKEN`. The GitHub root pins each one's version in `terraform.tfvars`, under
`organizations.<org>.governance_secrets`.

After each apply, the GitHub root's deploy job and the sweep run `.github/scripts/secret-sync.mjs`
as `infra-github`. It rewrites a repository's copy older than the pinned version, writes a missing
one, and deletes one no workflow names. A value travels only through a pipe from `gcloud` to `gh`.

To rotate one, add a version as in [Rotate a secret](#rotate-a-secret), then bump its pin in a pull
request. Its deploy copies it into every repository that names it.

## Alloy push token

Alloy pushes metrics, logs and traces to the production stack with one access policy token. Create
it in the stack's Grafana, under **Administration → Users and access → Cloud access policies**:

- **Scopes:** `metrics:write`, `logs:write` and `traces:write`, and nothing else.
- **Token:** no expiry.

Add the token as a version of `production-alloy-push-token`, as in
[Rotate a secret](#rotate-a-secret), and pin it in the cluster root's `addon_secret_versions`. For a
leak, delete the token in Grafana as well as disabling its version.

## pgBackRest TLS certificates

The database and repository hosts authenticate each other with certificates from an offline CA.
The hourly check fails 30 days before any certificate expires.

| Secret                                       | Contents                                       |
| -------------------------------------------- | ---------------------------------------------- |
| `production-<service>-pgbackrest-ca`         | CA certificate only, never its key             |
| `production-<service>-pgbackrest-database`   | client certificate followed by its private key |
| `production-<service>-pgbackrest-repository` | server certificate followed by its private key |

- **Client CN:** the service's `native_backups.<service>.client_name` in foundation's
  `terraform.tfvars`.
- **Server DNS name:** `agora-pgbackrest-<service>.europe-west1-d.c.a-novel-production-prod.internal`.

The CA's private key stays offline with its custodian, and never reaches a VM or Secret Manager.
`host-credentials` checks each bundle when a host starts, and refuses it unless:

- the CA secret holds only CA certificates, currently valid;
- each identity secret holds one unencrypted private key and its certificate, plus any
  intermediates, chaining to that CA and valid now;
- a client certificate allows TLS client authentication and has the client CN above;
- a server certificate allows TLS server authentication and has the server DNS name above;
- neither identity certificate is a CA.

To renew:

1. Issue the certificates offline, with the same names and purposes.
2. Upload each PEM file, here the database host's:

   ```bash
   SERVICE=json-keys
   ENDPOINT=database
   FILE=database.pem
   gcloud secrets versions add "production-$SERVICE-pgbackrest-$ENDPOINT" --project=a-novel-management-prod \
     --data-file="$FILE"
   ```

3. Bump the versions in one pull request:
   - for the database host, `native_backups.<service>.ca_version` and `identity_version` in
     foundation;
   - for the repository VM, `backup_repository.runtime.ca_version` and `identity_version` in the
     service root.
4. Merge it as a [database host change](database.md#change-a-database-host), during a planned
   downtime. The rollout restarts the database host, then the repository VM, which load the new
   certificates.

Delete the local PEM files afterwards.

## Audit access

```bash
SECRET="production-<service>-<name>"
gcloud logging read 'protoPayload.serviceName="secretmanager.googleapis.com" AND protoPayload.resourceName:"/secrets/'"$SECRET"'"' \
  --project=a-novel-management-prod --limit=20 --format='table(timestamp,protoPayload.methodName,protoPayload.authenticationInfo.principalEmail)'
```
