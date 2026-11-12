# Secrets

This runbook is about secret values. OpenTofu manages the secret containers, in the management
project. Humans add their values with `gcloud`, so the values never reach state, plans or Git. Each
workload reads the numeric version its root's `terraform.tfvars` pins, so a new value takes effect
only once a pull request pins it. External Secrets copies each pinned version into the namespace's
`secrets` Secret, and a pod reads it when it starts.

## Rotate a secret

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
   | `*-app-master-key`  | 64 hexadecimal characters                                 |
   | `*-openai-api-key`  | an OpenAI project key restricted to the Responses API     |
   | `*-waitlist-secret` | the invitation list's signing key, at least 32 characters |

   The invitation list's Apps Script holds the same key in its `WAITLIST_SECRET` script property,
   and every join fails while the two differ. Change both together, as service-authentication's
   [waitlist guide](https://github.com/a-novel/service-authentication/blob/master/scripts/waitlist/README.md#rotate-the-signing-key)
   shows.

2. **Pin the new number** in `secret_versions` in the service root, or in the cluster root's
   `addon_secret_versions` for an add-on, in a pull request, and merge it. The deploy points the
   namespace's `secrets` Secret at the new version. The running pods keep the value they started
   with, so the new one takes effect at the workload's next rollout, such as its next release.
3. **Disable the old version** once every pod that reads the secret has restarted on the new value:

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
there, such as in OpenAI's project.

The databases' passwords live in CloudNativePG's `database-app` Secrets, never in Secret Manager.

## SMTP (Google Workspace relay)

Authentication sends mail through the Google Workspace SMTP relay on port 587, with STARTTLS and no
credential: the relay admits it by the production NAT address. The authentication root's `smtp`
input names the relay and the sender.

The relay rule is in Google Admin under **Apps → Google Workspace → Gmail → Routing → SMTP relay
service**. Its settings are "only addresses in my domains", "only accept mail from the specified IP
addresses" with the NAT address alone, and "require TLS", without SMTP authentication. The address
is foundation's `cluster_nat_address`.

Health reporting `client:smtp` up proves only that the relay answers over TLS. Only a real email
proves that the relay accepts the service's address, so send one after any change to the rule or
to the [NAT address](../architecture.md#network).

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
  workflow posts to Fluxer before it lapses.

Add each one as a version of `production-github-dispatch-<org>`, as in
[Rotate a secret](#rotate-a-secret), and pin it in bootstrap's `github_dispatch_token_versions`. The
next dispatch after the deploy reads it. The token can start, rerun, cancel and delete workflow runs
in those repositories. For a leak, revoke it on GitHub as well as disabling its version.

GitHub records each dispatch as the token owner's, and role gates such as `require-role` read that
account's role. An admin's token therefore passes the admin gates of infra's `deploy.yaml`,
`downtime.yaml` and `recovery.yaml`, while the scheduled workflows gate on no role and need only
Write. Only `github-dispatcher` reads the token, and `github-dispatch` dispatches only the workflows
its schedules list.

## Grafana configuration tokens

The Grafana root reads one token per CI identity, from a service account of the production stack.
Create each one in the stack's Grafana, under **Administration → Users and access → Service
accounts**:

| Secret                            | Service account | Role                                    | Token expiry |
| --------------------------------- | --------------- | --------------------------------------- | ------------ |
| `production-grafana-plan-token`   | `infra-plan`    | No basic role, custom role `infra-plan` | 90 days      |
| `production-grafana-deploy-token` | `infra-deploy`  | Admin                                   | none         |

The deploy account is an Admin because Grafana caches each identity's folder permissions: an
Editor that creates a folder cannot read it back for a moment, which leaves the folder tainted.
Give neither account `alert.provisioning.secrets:read`, which **Read via Provisioning API + Export
Secrets** grants: it hands the `discord` contact point's webhook to pull-request code.

The plan account reads what the Grafana root manages and queries no data source, so its token
reads no log, trace or metric. Its custom role grants the folders, the dashboards and the alerting
configuration. `alert.provisioning:read` reads each alert rule without the query access to its data
sources that the rules API would require, and leaves contact points' secure fields out. Create the
role and give it to the account with the deploy token, as an operator:

```bash
GRAFANA_TOKEN="$(gcloud secrets versions access latest --secret=production-grafana-deploy-token --project=a-novel-management-prod)"
curl -sS --fail-with-body -H "Authorization: Bearer $GRAFANA_TOKEN" -H 'Content-Type: application/json' \
  https://anovel.grafana.net/api/access-control/roles -d '{
    "name": "custom:infra-plan", "uid": "infra-plan", "displayName": "infra-plan", "version": 1, "global": false,
    "description": "Reads what the Grafana root manages. Queries no data source.",
    "permissions": [
      {"action": "folders:read", "scope": "folders:*"},
      {"action": "dashboards:read", "scope": "folders:*"},
      {"action": "alert.rules:read", "scope": "folders:*"},
      {"action": "alert.notifications:read"},
      {"action": "alert.provisioning:read"}
    ]}'
PLAN_ACCOUNT="$(curl -sS --fail-with-body -H "Authorization: Bearer $GRAFANA_TOKEN" \
  'https://anovel.grafana.net/api/serviceaccounts/search?query=infra-plan' | jq -r '.serviceAccounts[] | select(.name == "infra-plan") | .id')"
curl -sS --fail-with-body -X PATCH -H "Authorization: Bearer $GRAFANA_TOKEN" -H 'Content-Type: application/json' \
  "https://anovel.grafana.net/api/serviceaccounts/$PLAN_ACCOUNT" -d '{"role": "None"}'
curl -sS --fail-with-body -X PUT -H "Authorization: Bearer $GRAFANA_TOKEN" -H 'Content-Type: application/json' \
  "https://anovel.grafana.net/api/access-control/users/$PLAN_ACCOUNT/roles" -d '{"roleUids": ["infra-plan"], "global": false}'
unset GRAFANA_TOKEN
```

Then re-run a Grafana root plan, which must still read "No changes". A plan that fails on a 403
names the permission the role lacks.

Add each token as a version of its secret, as in [Rotate a secret](#rotate-a-secret), and pin it in
the Grafana root's `token_versions`. Pull requests and the drift check read the plan token as
`infra-reviewed-plan`, and deploys the deploy token as `infra-grafana`. Create the plan token with a 90-day
expiry, under the account's **Add service account token**, and replace it every 60 days, so a lost
or leaked copy lapses on its own. The deploy token, which only master's deploy reads, has none. For
a leak, delete the token in Grafana as well as disabling its version.

Grafana's `discord` contact point is created by hand in the same stack, so its webhook never reaches
state. It uses Grafana's **Discord** integration with a Fluxer webhook URL, since Fluxer takes
Discord's format. Its title and message call the Grafana root's templates, as
[Grafana alerts](alerts.md#grafana-alerts) shows. If Fluxer refuses its posts, Grafana's **Slack**
integration takes the same URL with `/slack` appended.

## Grafana Cloud tokens

Frontend Observability's API takes a Grafana Cloud access policy token, which no stack service
account replaces, so bootstrap holds one for each CI identity of the Grafana root. Access policies
live in the Cloud Portal on grafana.com, not in the stack's Grafana. Create one policy and its token
for each row of the table:

1. Open the A-Novel organization's
   [Access Policies](https://grafana.com/orgs/anovel/access-policies) page, which the portal's left
   menu lists under **SECURITY**, and select **New access policy**.
2. Enter the row's policy name as **Display name** and **Name**.
3. Under **Realms**, open **Add a realm** and pick `anovel`, listed under `prod-eu-west-2`. The realm
   below the field changes from `anovel (all stacks)` to `anovel`.
4. Leave the **Scopes** table empty. Under **ADDITIONAL SCOPES**, add each of the row's scopes from
   **Add scope**, then select **Create access policy**.
5. Expand the token row at the bottom of the new policy's card and select **Add token**. Enter the
   policy name as **Token name**, keep **Expiration** at **No expiry**, select **Create token** and
   copy the token: Grafana shows it once.

| Secret                                  | Policy name    | Scopes                                                                                                        |
| --------------------------------------- | -------------- | ------------------------------------------------------------------------------------------------------------- |
| `production-grafana-cloud-plan-token`   | `infra-plan`   | `stacks:read`, `frontend-observability:read`                                                                  |
| `production-grafana-cloud-deploy-token` | `infra-deploy` | `stacks:read`, `frontend-observability:read`, `frontend-observability:write`, `frontend-observability:delete` |

Add each token as a version of its secret, as in [Rotate a secret](#rotate-a-secret), and pin it in
the Grafana root's `token_versions`. Pull requests and the drift check read the plan token as
`infra-reviewed-plan`, and deploys the deploy token as `infra-grafana`. For a leak, delete the token
on the same Access Policies page as well as disabling its version.

## Source-map upload keys

A platform's release build sends its browser source maps to its Faro app with a Grafana Cloud
access policy token, which the platform's `sourcemaps` environment holds as
`FARO_SOURCEMAP_API_KEY`. Create the access policy once in the Cloud Portal, under **Security →
Access policies**: name it `faro-sourcemaps`, give it the production stack as its realm, and the
`sourcemaps:read`, `sourcemaps:write` and `sourcemaps:delete` scopes. Then create one token per
platform, named after it, without an expiry.

Set a platform's token only once the GitHub root has applied its `sourcemaps` environment, which
the platform's `release.yaml` names: the environment then admits only `master`, `release/v*`
branches, the next major's `v<N>` branch and `v*` tags. `gh` prompts for the value:

```bash
gh secret set FARO_SOURCEMAP_API_KEY --env sourcemaps --repo a-novel/platform-studio
```

platform-template keeps no key, so its builds send nothing. For a leak, delete the token in the
Cloud Portal, then set a new one.

## GitHub root keys

The GitHub root reads one GitHub App key per organization and CI identity. Core creates each
organization's Plan App and Deploy App by hand, private to the organization and installed on all its
repositories, with these permissions. Neither holds Workflows, so neither can change a workflow file:

| Permission                 | Plan App | Deploy App | Used for                                                                                                                                                          |
| -------------------------- | -------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Repository: Administration | Read     | Write      | Settings, rulesets, collaborators and team grants, vulnerability alerts, workflow token permissions, the assert steps, environments and their deployment patterns |
| Repository: Actions        | Read     | Read       | Reading environments and deployment patterns                                                                                                                      |
| Repository: Contents       | Read     | Write      | Discovery, and creating a repository from a template. GitHub returns a repository's merge settings only to an App with Contents write                             |
| Repository: Environments   | Read     | Write      | Environment secret names, then secret sync                                                                                                                        |
| Repository: Issues         | Read     | Write      | Labels                                                                                                                                                            |
| Repository: Metadata       | Read     | Read       | Repositories, rulesets, collaborators                                                                                                                             |
| Repository: Pages          | Read     | Write      | Pages                                                                                                                                                             |
| Repository: Variables      | Read     | Write      | Repository variables: a dedicated bot's client ID, and each platform's `FARO_SOURCEMAP_APP_ID`                                                                    |
| Organization: Members      | Read     | Write      | Tier and area teams                                                                                                                                               |
| Organization: Secrets      | Read     | Write      | Scoped org secret access                                                                                                                                          |

The Deploy App also needs the organization's repository creation permission, which GitHub lists
beside Administration, and reads Code Quality's setup, which needs Administration write, for the
drift check. A permission added later takes effect only once each organization approves it, on its
settings' **GitHub Apps** page, where the installation shows the request.

Generate a private key under the App's **Private keys** settings, add the downloaded file as a
version of its secret, then delete the file:

```bash
SECRET="production-github-<plan|deploy>-key-<org>"
KEY_FILE="<path to the downloaded .pem>"
gcloud secrets versions add "$SECRET" --project=a-novel-management-prod --data-file="$KEY_FILE"
```

| Secret                               | App                     | Read by                                                                 |
| ------------------------------------ | ----------------------- | ----------------------------------------------------------------------- |
| `production-github-plan-key-<org>`   | the Plan App, read-only | `infra-reviewed-plan`, for pull requests                                |
| `production-github-deploy-key-<org>` | the Deploy App          | `infra-github` for deploys and the sweep, `infra-drift` for drift plans |

Replace each Plan App key every 90 days, since pull requests read it. Generate a new key, add it
as a version and bump `apps.<org>.plan.key_version` in the GitHub root's `terraform.tfvars`. Once
that pull request has merged, delete the old key in the App's settings and disable its version.

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

A repository whose Agent and Dependencies Apps are installed on it alone, listed in the GitHub
root's `dedicated_apps`, takes their keys instead:
`production-github-governance-<owner>-<name>-agent-bot-private-key` and
`…-dependency-bot-private-key`, pinned there as each App's `key_version`. The root also sets its
repository variables `AGENT_BOT_CLIENT_ID`, `AGENT_BOT_LOGIN`, `DEPENDENCY_BOT_CLIENT_ID` and
`DEPENDENCY_BOT_LOGIN`, which win over the organization's, so its workflows act as those Apps.

## Alloy push token

Alloy pushes metrics, logs and traces to the production stack with one access policy token. Create
its policy and token as in [Grafana Cloud tokens](#grafana-cloud-tokens), named `alloy-push`, with
only **WRITE** ticked for `metrics`, `logs` and `traces` in the **Scopes** table and no additional
scope.

Add the token as a version of `production-alloy-push-token`, as in
[Rotate a secret](#rotate-a-secret), and pin it in the cluster root's `addon_secret_versions`. For a
leak, delete the token on the Access Policies page as well as disabling its version.

## Audit access

```bash
SECRET="production-<service>-<name>"
gcloud logging read 'protoPayload.serviceName="secretmanager.googleapis.com" AND protoPayload.resourceName:"/secrets/'"$SECRET"'"' \
  --project=a-novel-management-prod --limit=20 --format='table(timestamp,protoPayload.methodName,protoPayload.authenticationInfo.principalEmail)'
```
