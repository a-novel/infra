# Provision and verify the workload foundation

> First production run: step 2. Start only after management-plane bootstrap passes; finish the
> protected plans, independent verification, and temporary-access cleanup before inspecting the host.

Use this runbook to prepare, provision, and independently verify the replaceable production workload
project and its private foundation. It covers project parent and billing authority, protected GitHub
inputs, project adoption, private routing, runtime identities, Artifact Registry, cost controls, and
the idle private PostgreSQL host, daily snapshots, recovery IAM/alerting, and removal of temporary
broad access.

## Operator context

Start a disposable Bash session so a strict-mode failure returns to the original terminal:

```bash
bash
```

Review `WORKLOAD_PROJECT_ID` and the four alert/operator assignments, then paste this complete block
before section 1 or after reopening the shell.

```bash
set -euo pipefail
set +x
umask 077

REPOSITORY='a-novel/infra'
REGION='europe-west1'
DATABASE_ZONE='europe-west1-b'
SUBNET_CIDR='10.20.0.0/24'
WORKLOAD_PROJECT_NAME='Agora production'

MANAGEMENT_PROJECT_ID="$(gh variable get GCP_MANAGEMENT_PROJECT_ID --repo "$REPOSITORY")"
BACKUP_BUCKET_NAME="$(gh variable get GCP_BACKUP_BUCKET --repo "$REPOSITORY")"
WORKLOAD_PROJECT_ID='agora-production-prod'
BILLING_ACCOUNT_ID="$(gcloud billing projects describe "$MANAGEMENT_PROJECT_ID" \
  --format='value(billingAccountName.basename())')"
OPERATOR_EMAIL="$(gcloud config get-value account 2>/dev/null)"
COST_ALERT_EMAIL="$OPERATOR_EMAIL"
OPERATIONS_ALERT_EMAIL="$OPERATOR_EMAIL"
DATABASE_OPERATOR_PRINCIPAL="user:${OPERATOR_EMAIL}"
AUTH_INITIALIZER_PRINCIPAL="user:${OPERATOR_EMAIL}"
OPERATOR_PRINCIPAL="user:${OPERATOR_EMAIL}"

PROJECT_PARENT_TYPE="$(gcloud projects describe "$MANAGEMENT_PROJECT_ID" \
  --format='value(parent.type)')"
PROJECT_PARENT_ID="$(gcloud projects describe "$MANAGEMENT_PROJECT_ID" \
  --format='value(parent.id)')"
ORGANIZATION_ID=''
FOLDER_ID=''
case "$PROJECT_PARENT_TYPE" in
  organization) ORGANIZATION_ID="$PROJECT_PARENT_ID" ;;
  folder) FOLDER_ID="$PROJECT_PARENT_ID" ;;
  '') ;;
  *) printf 'Unexpected project parent type: %s\n' "$PROJECT_PARENT_TYPE" >&2; false ;;
esac
unset PROJECT_PARENT_TYPE PROJECT_PARENT_ID

FOUNDATION_SERVICE_ACCOUNT="infra-foundation@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com"
PLAN_SERVICE_ACCOUNT="infra-plan@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com"
DATABASE_OPERATOR_PRINCIPALS="$(
  jq -cn --arg principal "$DATABASE_OPERATOR_PRINCIPAL" '[$principal]'
)"
AUTH_INITIALIZER_PRINCIPALS="$(
  jq -cn --arg principal "$AUTH_INITIALIZER_PRINCIPAL" '[$principal]'
)"
```

## Authorization gate

Merging this repository creates nothing. Do not execute a mutating command or dispatch `apply` until
the user responsible for this Google Cloud account explicitly authorizes resource creation and all
of the following are true:

1. the management-plane bootstrap is applied to its remote state and independently verified;
2. `.github/workflows/foundation.yaml` exists on `master` and authenticates through its exact WIF provider;
3. `production-foundation` requires a reviewer, disallows administrator bypass, and accepts only
   protected `master` deployments;
4. a maintainer explicitly authorizes the initial workload-project creation;
5. the plan run completed from the same current `master` commit and its sanitized summary was reviewed.

Agents never run `gcloud` or `tofu apply`. Operators must not substitute a local OpenTofu apply: it
would bypass protected approval, remote plan custody, log sanitization, and the root-specific
automation identity.

## Result and non-result

The completed procedure creates:

- one workload project linked to the selected billing account;
- thirteen workload APIs, one custom VPC, one regional `/24` subnet, two restricted Google API routes,
  six firewall rules, and three private DNS zones;
- seven keyless runtime identities, twelve exact cross-project secret IAM bindings, and separate
  create-only backup/read-only restore bucket IAM;
- deprivileged default Google service accounts so none retains a primitive project role;
- one immutable regional Docker repository and narrow release/database access;
- one pinned Shielded COS template, one continuously running `e2-medium` in a stateful one-member
  group, one 20 GiB replaceable boot disk, one 50 GiB preserved balanced data disk, and one
  stateful internal address with a daily `europe-west1` snapshot schedule and seven-day retention;
- four regional quota preferences, one two-project alert-only budget of 60 units in the billing
  account currency, separate cost and operations email channels, eight native alert policies,
  30-day default logging, and one narrow successful-health exclusion. The existing read-only drift
  workflow performs the production synthetic health check only after releases are enabled.

It does not create a running PostgreSQL container, logical-backup schedule, Cloud Run service or job,
public IP, load balancer, Cloud NAT, router, VPC connector, secret payload, or application release. The VM
stays idle because both release-manifest components are disabled. PostgreSQL and private gRPC are not
callable after this procedure.

## Security rules for every step

- Use a secured human Google account with phishing-resistant MFA and retained offline recovery codes.
- Never enable shell tracing with `set -x`; do not paste environment dumps, IAM policies, plan JSON,
  billing identifiers, email addresses, or tokens into a public issue, pull request, or CI log.
- Run mutating Google commands only when a section explicitly says the stop condition has been
  lifted. Every command below is for a human operator; an agent supplies guidance and waits for
  sanitized results.
- Use the exact `infra-foundation` identity for protected infrastructure. Never create or download a
  service-account key.
- Never delete the workload project to recover from a partial first run. Preserve it, freeze writers,
  reconcile state, and resume from the exact reviewed commit.
- Removing, replacing, or forgetting any managed resource requires the repository's deliberate
  destructive-change gate in addition to normal approval. This initial plan must contain none.

## Prerequisites

- The [management-plane bootstrap](./bootstrap-management-plane.md) completed successfully, including
  remote state, WIF, exact IAM, GitHub environment protection, and removal of temporary bootstrap
  authority.
- The operator has `gcloud`, `gh`, `jq`, and an authenticated browser. The operator's active Google
  account can manage the selected billing account and, when present, organization or folder IAM.
- The billing account is open, has a valid payment instrument, and the operator can link a project.
- The desired workload project ID has never been used. Google project IDs are global, immutable, and
  cannot be reused after deletion.
- The cost-alert and operations-alert addresses are monitored by humans. If either is a group, it
  accepts the documented Google Cloud Billing and Monitoring senders. Cost owns billing/quota
  follow-up; operations owns service, job, backup, and database incidents.
- Select at least one named database operator as a `user:` or `group:` IAM member. This identity
  receives privileged OS Login through IAP and must use MFA. A cross-organization operator also
  needs OS Login External User from its own organization administrator.
- Select at least one named Authentication initializer as a `user:` or `group:` IAM member. This
  human receives the narrow ability to provision and invoke the one-time initializer as its dedicated
  identity. Use a group when several people share the duty; never use a service account.
- The first foundation pull request and its complete sanitized plan have been reviewed. No change
  targets an unrelated project, parent, billing account, network, or secret container.

## 1. Collect and validate non-payload inputs

The operator-context block supplies every stable value. Validate it before reading or mutating a
Google Cloud resource.

```bash
[[ "$MANAGEMENT_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$WORKLOAD_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$MANAGEMENT_PROJECT_ID" != "$WORKLOAD_PROJECT_ID" ]]
[[ "$BILLING_ACCOUNT_ID" =~ ^[0-9A-Z]{6}-[0-9A-Z]{6}-[0-9A-Z]{6}$ ]]
[[ "$COST_ALERT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
[[ "$OPERATIONS_ALERT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
[[ "$DATABASE_ZONE" == "${REGION}-"* ]]
[[ "$DATABASE_OPERATOR_PRINCIPAL" =~ ^(user|group):[^[:space:]@]+@[^[:space:]@]+$ ]]
[[ "$AUTH_INITIALIZER_PRINCIPAL" =~ ^(user|group):[^[:space:]@]+@[^[:space:]@]+$ ]]
[[ "$OPERATOR_PRINCIPAL" =~ ^user:[^[:space:]@]+@[^[:space:]@]+$ ]]
[[ -z "$ORGANIZATION_ID" || "$ORGANIZATION_ID" =~ ^[0-9]+$ ]]
[[ -z "$FOLDER_ID" || "$FOLDER_ID" =~ ^[0-9]+$ ]]
[[ -z "$ORGANIZATION_ID" || -z "$FOLDER_ID" ]]
jq -e 'length >= 1' <<<"$DATABASE_OPERATOR_PRINCIPALS" >/dev/null
jq -e 'length >= 1' <<<"$AUTH_INITIALIZER_PRINCIPALS" >/dev/null

printf 'Repository: %s\nManagement project: %s\nWorkload project: %s\nRegion: %s\nDatabase zone: %s\nSubnet: %s\n' \
  "$REPOSITORY" "$MANAGEMENT_PROJECT_ID" "$WORKLOAD_PROJECT_ID" "$REGION" "$DATABASE_ZONE" "$SUBNET_CIDR"
```

Expected safe result: the final six selections match the intended projects and fixed EU location,
all validations exit zero, and at most one parent ID is populated. Do not print the billing account,
either alert address, operator or initializer principal, or either JSON principal set.

Verify the active identities and stable bootstrap resources without changing anything:

```bash
gcloud auth list --filter=status:ACTIVE --format='table(account,status)'
gh auth status

gcloud projects describe "$MANAGEMENT_PROJECT_ID" \
  --format='yaml(projectId,projectNumber,lifecycleState)'
MANAGEMENT_PROJECT_NUMBER="$(gcloud projects describe "$MANAGEMENT_PROJECT_ID" --format='value(projectNumber)')"
[[ "$MANAGEMENT_PROJECT_NUMBER" =~ ^[0-9]+$ ]]
[[ "$BACKUP_BUCKET_NAME" == "${MANAGEMENT_PROJECT_ID}-${MANAGEMENT_PROJECT_NUMBER}-backups" ]]
gcloud storage buckets describe "gs://${BACKUP_BUCKET_NAME}" \
  --format='yaml(name,location,public_access_prevention,uniform_bucket_level_access,retention_policy,lifecycle_config,soft_delete_policy)'
gcloud iam service-accounts describe "$FOUNDATION_SERVICE_ACCOUNT" \
  --project="$MANAGEMENT_PROJECT_ID" \
  --format='yaml(email,disabled,uniqueId)'
gcloud billing accounts describe "$BILLING_ACCOUNT_ID" \
  --format='yaml(open,currencyCode)'
BILLING_CURRENCY_CODE="$(gcloud billing accounts describe "$BILLING_ACCOUNT_ID" --format='value(currencyCode)')"
[[ "$BILLING_CURRENCY_CODE" =~ ^[A-Z]{3}$ ]]
```

Expected safe result: one intended Google account is active, GitHub is authenticated to the intended
account, both project and service account are active, the foundation account is not disabled, the
backup bucket is the protected EU bucket from bootstrap, and the billing account reports `open:
true` with a three-letter currency code. Share only the boolean and currency code if assistance is
needed.

Screen the proposed workload ID before authorizing creation:

```bash
! gcloud projects describe "$WORKLOAD_PROJECT_ID"
```

Do not continue when metadata is returned. `NOT_FOUND` or a permission error only means the project
is not visible to this account; the first protected plan is the authoritative availability check.
Choose another ID after an `ALREADY_EXISTS` response.

## 2. Choose exactly one project-parent path

### Organization or folder path (preferred when one already exists)

Do not buy or create an organization solely for this deployment. When an organization/folder exists,
grant project creation only at the narrowest selected parent. These commands are mutating; run them
only after the authorization gate is lifted.

For a folder:

```bash
gcloud resource-manager folders add-iam-policy-binding "$FOLDER_ID" \
  --member="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --role='roles/resourcemanager.projectCreator' \
  --condition=None
```

For an organization without a selected folder:

```bash
gcloud organizations add-iam-policy-binding "$ORGANIZATION_ID" \
  --member="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --role='roles/resourcemanager.projectCreator' \
  --condition=None
```

Never run both. Google grants the project creator temporary `roles/owner` on the project it creates;
section 8 removes that exact binding and the parent-level creator role after exact IAM converges.

Verify only the chosen parent:

```bash
if [[ -n "$FOLDER_ID" ]]; then
  gcloud resource-manager folders get-iam-policy "$FOLDER_ID" \
    --flatten='bindings[].members' \
    --filter="bindings.role=roles/resourcemanager.projectCreator AND bindings.members=serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
    --format='table(bindings.role,bindings.members)'
elif [[ -n "$ORGANIZATION_ID" ]]; then
  gcloud organizations get-iam-policy "$ORGANIZATION_ID" \
    --flatten='bindings[].members' \
    --filter="bindings.role=roles/resourcemanager.projectCreator AND bindings.members=serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
    --format='table(bindings.role,bindings.members)'
else
  printf 'Standalone path selected; do not grant parent authority.\n'
fi
```

Expected safe result: exactly one Project Creator row for the foundation service account, or the
standalone message.

### Standalone path (no organization or folder)

Google has no parent resource on which to grant a service account Project Creator for a standalone
account. After explicit creation authorization, the human operator creates and bills the empty
project, then grants the foundation identity temporary Owner so exact code-managed IAM can converge:

```bash
[[ -z "$ORGANIZATION_ID" && -z "$FOLDER_ID" ]]

gcloud projects create "$WORKLOAD_PROJECT_ID" \
  --name="$WORKLOAD_PROJECT_NAME" \
  --set-as-default=false
gcloud billing projects link "$WORKLOAD_PROJECT_ID" \
  --billing-account="$BILLING_ACCOUNT_ID"
gcloud projects add-iam-policy-binding "$WORKLOAD_PROJECT_ID" \
  --member="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --role='roles/owner' \
  --condition=None
```

This creates only the project and billing link. Google can attach its standard empty `default` VPC
to a manually created project. Do not enable APIs, attach workloads, edit that VPC, or add another
network manually. Before its first plan, the protected workflow must import the project into the
remote foundation state as `google_project.workload`. Applying the declared
`auto_create_network = false` then deliberately removes Google's empty default VPC before the custom
production VPC is created. Set `adopt_existing_project` in the protected configuration below;
OpenTofu's declarative import block then shows the adoption in the saved plan and performs it only
during exact-plan apply. Do not run `tofu import` or delete the default VPC from a local checkout.

Verification:

```bash
gcloud projects describe "$WORKLOAD_PROJECT_ID" \
  --format='yaml(projectId,name,lifecycleState,parent)'
gcloud billing projects describe "$WORKLOAD_PROJECT_ID" \
  --format='yaml(projectId,billingEnabled)'
```

Expected safe result: the intended project is active and billing is enabled. Do not enable Compute
Engine merely to inspect its possible default VPC. The protected adoption later enables the required
API, removes only that empty provider-created VPC, and proves that `agora-production` is the sole
network.

## 3. Grant exact billing-account prerequisites

The foundation identity needs Billing Account User only to attach the new project and Billing Account
Costs Manager to manage its budget. It does not need Billing Account Administrator. These commands
are mutating; run them only after the authorization gate is lifted. Cloud Billing IAM does not
support conditional bindings, so grant only these exact members and roles.

```bash
gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT_ID" \
  --member="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --role='roles/billing.user' \
  --format=none
gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT_ID" \
  --member="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --role='roles/billing.costsManager' \
  --format=none
gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT_ID" \
  --member="serviceAccount:${PLAN_SERVICE_ACCOUNT}" \
  --role='roles/billing.viewer' \
  --format=none
```

Verify without dumping the rest of the billing policy:

```bash
gcloud billing accounts get-iam-policy "$BILLING_ACCOUNT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.members=serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --format='table(bindings.role,bindings.members)'
gcloud billing accounts get-iam-policy "$BILLING_ACCOUNT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.members=serviceAccount:${PLAN_SERVICE_ACCOUNT}" \
  --format='table(bindings.role,bindings.members)'
```

Expected safe result: exactly `roles/billing.costsManager` and `roles/billing.user`. The latter is
removed after first convergence; Costs Manager remains so later reviewed budget edits work. The plan
identity has only `roles/billing.viewer`, which is required to refresh the code-managed budget during
the read-only drift plan and cannot change billing or spend.

## 4. Store the protected foundation input bundle

The `production-foundation` environment must already have the protections established by the
bootstrap runbook. Verify them before writing values:

```bash
gh api "repos/${REPOSITORY}/environments/production-foundation" \
  --jq '{name,protected_branches:.deployment_branch_policy.protected_branches,custom_branch_policies:.deployment_branch_policy.custom_branch_policies,reviewers:[.protection_rules[]? | select(.type=="required_reviewers") | .reviewers[].reviewer.login]}'
```

Expected safe result: the environment name is exact, protected branches are enabled, custom branch
policies are disabled, and the configured reviewer appears. Confirm administrator bypass
is disabled in **Repository settings → Environments → production-foundation**; GitHub's public API
does not expose a reliable verification field for that switch.

Store one complete JSON document instead of a collection of loosely coupled variables. This keeps
the workflow interface small, masks privileged human identifiers and billing metadata as one value,
and lets the compiler reuse the same reviewed capacity defaults for a disposable recovery project.
It contains no application secret payload.

```bash
if [[ -z "$ORGANIZATION_ID" && -z "$FOLDER_ID" ]]; then
  ADOPT_EXISTING_PROJECT=true
else
  ADOPT_EXISTING_PROJECT=false
fi

FOUNDATION_CONFIG_FILE="$(mktemp)"
jq -n \
  --arg management_project_id "$MANAGEMENT_PROJECT_ID" \
  --arg workload_project_id "$WORKLOAD_PROJECT_ID" \
  --arg workload_project_name "$WORKLOAD_PROJECT_NAME" \
  --arg backup_bucket_name "$BACKUP_BUCKET_NAME" \
  --arg billing_account_id "$BILLING_ACCOUNT_ID" \
  --arg organization_id "$ORGANIZATION_ID" \
  --arg folder_id "$FOLDER_ID" \
  --arg region "$REGION" \
  --arg subnet_cidr "$SUBNET_CIDR" \
  --arg database_zone "$DATABASE_ZONE" \
  --argjson database_operator_principals "$DATABASE_OPERATOR_PRINCIPALS" \
  --argjson authentication_initializer_principals "$AUTH_INITIALIZER_PRINCIPALS" \
  --arg cost_alert_email "$COST_ALERT_EMAIL" \
  --arg operations_alert_email "$OPERATIONS_ALERT_EMAIL" \
  --argjson adopt_existing_project "$ADOPT_EXISTING_PROJECT" \
  '{
    management_project_id: $management_project_id,
    workload_project_id: $workload_project_id,
    workload_project_name: $workload_project_name,
    backup_bucket_name: $backup_bucket_name,
    billing_account_id: $billing_account_id,
    organization_id: (if $organization_id == "" then null else $organization_id end),
    folder_id: (if $folder_id == "" then null else $folder_id end),
    region: $region,
    subnet_cidr: $subnet_cidr,
    database_zone: $database_zone,
    database_operator_principals: $database_operator_principals,
    authentication_initializer_principals: $authentication_initializer_principals,
    cost_alert_email: $cost_alert_email,
    operations_alert_email: $operations_alert_email,
    adopt_existing_project: $adopt_existing_project
  }' >"$FOUNDATION_CONFIG_FILE"

jq -e '
  ((.organization_id == null) or (.folder_id == null)) and
  (.database_operator_principals | length >= 1) and
  (.authentication_initializer_principals | length >= 1) and
  (.adopt_existing_project == ((.organization_id == null) and (.folder_id == null)))
' "$FOUNDATION_CONFIG_FILE" >/dev/null

for environment in production-foundation production-recovery; do
  gh secret set FOUNDATION_TFVARS_JSON \
    --repo "$REPOSITORY" --env "$environment" \
    <"$FOUNDATION_CONFIG_FILE"
done

rm -f -- "$FOUNDATION_CONFIG_FILE"
unset FOUNDATION_CONFIG_FILE ADOPT_EXISTING_PROJECT
unset COST_ALERT_EMAIL OPERATIONS_ALERT_EMAIL
unset DATABASE_OPERATOR_PRINCIPAL DATABASE_OPERATOR_PRINCIPALS
unset AUTH_INITIALIZER_PRINCIPAL AUTH_INITIALIZER_PRINCIPALS
```

`COST_ALERT_EMAIL` receives budget notifications and Cloud Quotas review follow-up.
`OPERATIONS_ALERT_EMAIL` receives service, job, database, and recovery incidents; both receive the
budget. Neither carries cloud authority. The protected foundation service account owns the
code-managed quota and monitoring roles. Verify names without printing values:

```bash
gh secret list --repo "$REPOSITORY" --env production-foundation
gh secret list --repo "$REPOSITORY" --env production-recovery
```

Expected safe result: `production-foundation` contains `BOOTSTRAP_TFVARS_JSON` and
`FOUNDATION_TFVARS_JSON`; `production-recovery` contains only `FOUNDATION_TFVARS_JSON`. Database
capacity, the pinned COS image, budgets, and quotas remain reviewed OpenTofu defaults rather than
mutable workflow inputs.

## 5. Create and apply exact protected plans

Reconcile bootstrap first, then foundation. Each `plan` dispatch stores one opaque binary plan and
small non-sensitive custody record in the matching state prefix. Its ID is the plan workflow's
`run-id-attempt`; it expires after 24 hours and can be consumed only once by the same commit and root.
The environment reviewer approves both runs, but only the `apply` run mutates cloud resources.

```bash
MASTER_SHA="$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)"
printf 'Planning commit: %s\n' "$MASTER_SHA"

gh workflow run foundation.yaml --repo "$REPOSITORY" --ref master \
  -f operation=plan -f root=bootstrap
gh run list --repo "$REPOSITORY" --workflow foundation.yaml --branch master \
  --event workflow_dispatch --limit 5 \
  --json databaseId,headSha,displayTitle,status,conclusion,url
```

Select the row titled `foundation plan bootstrap`, verify `headSha` equals `MASTER_SHA`, then watch
it and derive its exact plan ID:

```bash
PLAN_RUN_ID='replace-with-bootstrap-plan-run-id'
test "$(gh api "repos/${REPOSITORY}/actions/runs/${PLAN_RUN_ID}" --jq .head_sha)" = "$MASTER_SHA"
gh run watch "$PLAN_RUN_ID" --repo "$REPOSITORY" --exit-status
PLAN_ATTEMPT="$(gh api "repos/${REPOSITORY}/actions/runs/${PLAN_RUN_ID}" --jq .run_attempt)"
PLAN_ID="${PLAN_RUN_ID}-${PLAN_ATTEMPT}"
printf 'Bootstrap plan ID: %s\n' "$PLAN_ID"
```

Review the plan job log. It may contain only action counts grouped by resource type, the plan ID,
and control messages—never addresses, values, outputs, configuration, or provider diagnostics.
Confirm the current `master` commit is still unchanged, then apply that plan:

```bash
test "$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)" = "$MASTER_SHA"
gh workflow run foundation.yaml --repo "$REPOSITORY" --ref master \
  -f operation=apply -f root=bootstrap -f plan_id="$PLAN_ID"
```

Approve the `production-foundation` deployment, select the new `foundation apply bootstrap` row with
the same `headSha`, and watch it to success. Repeat the exact sequence with `root=foundation`:

```bash
gh workflow run foundation.yaml --repo "$REPOSITORY" --ref master \
  -f operation=plan -f root=foundation
gh run list --repo "$REPOSITORY" --workflow foundation.yaml --branch master \
  --event workflow_dispatch --limit 5 \
  --json databaseId,headSha,displayTitle,status,conclusion,url
```

Set `PLAN_RUN_ID` to the `foundation plan foundation` row, repeat the SHA/watch/attempt commands,
review the summary, and dispatch `operation=apply`, `root=foundation`, and that new `PLAN_ID`.
An apply attempt consumes the plan before mutation and then proves a zero-change convergence plan; a retry cannot
apply the same plan twice.

Any deletion, replacement, or state-forget action fails unless the one pull request associated with
`MASTER_SHA` already carried the exact `allow-resource-deletion` label before merge. Adding a label
after merge is deliberately insufficient. The initial foundation should need no such exception.

The expected initial summary contains either one project creation or one declarative project import/update, thirteen APIs, the
network/subnet/routes, six firewalls, three zones and their records, seven service accounts, one
invocation tag key with five values, exact conditional IAM, two narrow Cloud Run custom roles, one
repository, one data disk, one immutable instance template, one stateful instance-group
manager, one snapshot policy/attachment, eight monitoring alerts, four quota preferences, one
budget, two notification channels, and logging controls. It
contains zero managed-resource delete, replacement, state-forget, Cloud Run service/job, router,
NAT, connector, load balancer, secret-version, or service-account-key actions. For standalone
adoption, the reviewed
`google_project` update also has the documented provider side effect of removing Google's empty
default VPC; no workload may be attached to it. Do not approve a plan that differs without changing
and reviewing the code and this runbook.

## 6. Verify project, billing, APIs, and IAM after apply

Continue in the same private shell so the validated section 1 values remain available. If that
shell closed, collect section 1 again before continuing.

```bash
gcloud projects describe "$WORKLOAD_PROJECT_ID" \
  --format='yaml(projectId,projectNumber,name,parent,lifecycleState,labels)'
gcloud billing projects describe "$WORKLOAD_PROJECT_ID" \
  --format='yaml(projectId,billingEnabled)'
gcloud services list --enabled --project="$WORKLOAD_PROJECT_ID" \
  --filter='config.name:(artifactregistry.googleapis.com cloudscheduler.googleapis.com cloudquotas.googleapis.com cloudresourcemanager.googleapis.com compute.googleapis.com dns.googleapis.com iam.googleapis.com iap.googleapis.com logging.googleapis.com monitoring.googleapis.com oslogin.googleapis.com run.googleapis.com serviceusage.googleapis.com)' \
  --format='value(config.name)' | sort
```

Expected safe result: the project is active with the selected parent and labels, billing is enabled,
and exactly the thirteen expected service names appear in the filtered list.

Verify no service account has an unexpected primitive project role and no project service account has
a user-managed key. The all-account enumeration is intentional: a newly introduced or
provider-created account must not escape this check.

```bash
gcloud projects get-iam-policy "$WORKLOAD_PROJECT_ID" \
  --format=json \
| jq -r '
    .bindings[]
    | select(.role == "roles/owner" or .role == "roles/editor")
    | .role as $role
    | .members[]
    | select(startswith("serviceAccount:"))
    | [$role, .]
    | @tsv
  '

PROJECT_SERVICE_ACCOUNTS="$(gcloud iam service-accounts list \
  --project="$WORKLOAD_PROJECT_ID" \
  --format='value(email)')"
[[ -n "$PROJECT_SERVICE_ACCOUNTS" ]]
while IFS= read -r account_email; do
  USER_KEY_NAMES="$(gcloud iam service-accounts keys list \
    --project="$WORKLOAD_PROJECT_ID" \
    --iam-account="$account_email" \
    --managed-by=user \
    --format='value(name)')"
  if [[ -n "$USER_KEY_NAMES" ]]; then
    printf 'STOP: user-managed key exists for %s.\n' "$account_email" >&2
    false
  fi
done <<<"$PROJECT_SERVICE_ACCOUNTS"
unset PROJECT_SERVICE_ACCOUNTS USER_KEY_NAMES
printf 'All project service accounts have zero user-managed keys.\n'
```

Expected safe result: at most one Owner row for the foundation creator before cleanup, no Editor row
for any service account—including the default Compute Engine service account—and the final zero-key
message. A key is an incident: disable it, preserve audit evidence, identify its creator, and do not
continue.

Verify only the intended cross-project Secret Manager members without accessing payloads:

```bash
for secret in \
  production-authentication-postgres-dsn \
  production-authentication-postgres-password \
  production-authentication-postgres-backup-password \
  production-authentication-smtp-sender-password \
  production-authentication-super-admin-password \
  production-json-keys-app-master-key \
  production-json-keys-postgres-dsn \
  production-json-keys-postgres-password \
  production-json-keys-postgres-backup-password; do
  gcloud secrets get-iam-policy "$secret" \
    --project="$MANAGEMENT_PROJECT_ID" \
    --flatten='bindings[].members' \
    --filter='bindings.role=roles/secretmanager.secretAccessor' \
    --format='table(bindings.members)'
done
```

Expected safe result: every configured human operator appears on all nine secrets. No `infra-*`
GitHub automation identity appears. Authentication appears only on its DSN and SMTP password.
Authentication initializer appears only on
the same DSN and the super-admin password; JSON Keys appears only on its master key and DSN; database
host appears on the four owner/backup passwords; backup appears only on the two backup passwords.
Restore, scheduler, release, plan, and foundation identities do not appear. This filtered view
intentionally omits the operators' separate Secret Version Manager bindings. Never run
`versions access` as a verification shortcut.

Verify that the release deployment role cannot execute a job or override an execution:

```bash
gcloud iam roles describe infraReleaseCloudRunDeployer \
  --project="$WORKLOAD_PROJECT_ID" \
  --format=json \
| jq --exit-status '
    (.includedPermissions | sort) == ([
      "run.jobs.create",
      "run.jobs.createTagBinding",
      "run.jobs.delete",
      "run.jobs.deleteTagBinding",
      "run.jobs.get",
      "run.jobs.list",
      "run.jobs.listEffectiveTags",
      "run.jobs.listTagBindings",
      "run.jobs.update",
      "run.executions.get",
      "run.executions.list",
      "run.locations.list",
      "run.operations.get",
      "run.revisions.get",
      "run.revisions.list",
      "run.services.create",
      "run.services.createTagBinding",
      "run.services.delete",
      "run.services.deleteTagBinding",
      "run.services.get",
      "run.services.list",
      "run.services.listEffectiveTags",
      "run.services.listTagBindings",
      "run.services.update"
    ] | sort)
  '
```

Expected safe result: `true`. `run.jobs.run`, `run.jobs.runWithOverrides`, every Cloud Run IAM-policy
permission, project IAM, secret access, and networking permissions are absent.

Verify the human-only initializer deployer separately:

```bash
gcloud iam roles describe authenticationInitializerDeployer \
  --project="$WORKLOAD_PROJECT_ID" --format=json \
| jq --exit-status '
    (.includedPermissions | sort) == ([
      "run.executions.get",
      "run.executions.list",
      "run.jobs.create",
      "run.jobs.createTagBinding",
      "run.jobs.delete",
      "run.jobs.deleteTagBinding",
      "run.jobs.get",
      "run.jobs.list",
      "run.jobs.listEffectiveTags",
      "run.jobs.listTagBindings",
      "run.jobs.update",
      "run.locations.list",
      "run.operations.get"
    ] | sort)
  '
```

Expected safe result: `true`. In particular, this role has neither `run.jobs.runWithOverrides` nor
Cloud Run IAM-policy access. Normal execution comes only from the separate initializer-tag condition.

Verify the five permanent authorization tags and the four production invocation conditions:

```bash
WORKLOAD_PROJECT_NUMBER="$(gcloud projects describe "$WORKLOAD_PROJECT_ID" \
  --format='value(projectNumber)')"
INVOCATION_TAG_KEY="$(gcloud resource-manager tags keys list \
  --parent="projects/${WORKLOAD_PROJECT_NUMBER}" \
  --filter='shortName=agora-invocation' --format='value(name)')"
[[ "$INVOCATION_TAG_KEY" =~ ^tagKeys/[0-9]+$ ]]

gcloud resource-manager tags values list --parent="$INVOCATION_TAG_KEY" --format=json \
| jq --exit-status '
    ([.[].shortName] | sort) ==
    (["initializer", "internal", "recovery", "release", "scheduled"] | sort) and
    all(.[].name; test("^tagValues/[0-9]+$"))
  '

gcloud projects get-iam-policy "$WORKLOAD_PROJECT_ID" --format=json \
| jq --exit-status '
    [
      .bindings[]
      | select(.role == "roles/run.jobsExecutor" or .role == "roles/run.servicesInvoker")
      | {role, title: .condition.title}
    ] | sort == ([
      {role: "roles/run.jobsExecutor", title: "AuthenticationInitializerOnly"},
      {role: "roles/run.jobsExecutor", title: "ReleaseTaggedCloudRunOnly"},
      {role: "roles/run.jobsExecutor", title: "ScheduledCloudRunOnly"},
      {role: "roles/run.servicesInvoker", title: "InternalCloudRunOnly"}
    ] | sort)
  '
```

Expected safe result: both checks return `true`. Inspect the four filtered bindings privately:
`AuthenticationInitializerOnly` names only the initializer set, `InternalCloudRunOnly` names only
Authentication runtime, `ReleaseTaggedCloudRunOnly` names only release automation, and
`ScheduledCloudRunOnly` names only scheduler runtime. Every expression must use
`resource.matchTagId` with the matching permanent key/value above. Production must have no
`RecoveryTaggedCloudRunOnly` or `RecoverySmokeCloudRunOnly` binding. Do not paste the policy output
into a public issue.

Verify each configured initializer appears in all five required human grants and that the release
service account appears in none of them:

```bash
INITIALIZER_TAG_VALUE="$(gcloud resource-manager tags values list \
  --parent="$INVOCATION_TAG_KEY" --filter='shortName=initializer' --format='value(name)')"
[[ "$INITIALIZER_TAG_VALUE" =~ ^tagValues/[0-9]+$ ]]

gcloud resource-manager tags values get-iam-policy "$INITIALIZER_TAG_VALUE" \
  --flatten='bindings[].members' --filter='bindings.role=roles/resourcemanager.tagUser' \
  --format='table(bindings.members)'
gcloud iam service-accounts get-iam-policy \
  "agora-auth-initializer@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" \
  --project="$WORKLOAD_PROJECT_ID" --flatten='bindings[].members' \
  --filter='bindings.role=roles/iam.serviceAccountUser' --format='table(bindings.members)'
gcloud artifacts repositories get-iam-policy agora-production \
  --project="$WORKLOAD_PROJECT_ID" --location="$REGION" \
  --flatten='bindings[].members' --filter='bindings.role=roles/artifactregistry.reader' \
  --format='table(bindings.members)'
gcloud projects get-iam-policy "$WORKLOAD_PROJECT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.role=projects/${WORKLOAD_PROJECT_ID}/roles/authenticationInitializerDeployer" \
  --format='table(bindings.members)'
```

The fifth grant is the `AuthenticationInitializerOnly` project binding inspected above. Expected
safe result: each named initializer is present in all five places; the release, scheduler, recovery,
and runtime service accounts are absent from the initializer tag, initializer `actAs`, deployer, and
initializer condition. The registry reader output may also contain the database runtime.

Verify the two runtime bucket roles without displaying unrelated members:

```bash
gcloud storage buckets get-iam-policy "gs://${BACKUP_BUCKET_NAME}" --format=json \
  | jq --exit-status \
      --arg backup "serviceAccount:agora-backup@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" \
      --arg restore "serviceAccount:agora-restore@${WORKLOAD_PROJECT_ID}.iam.gserviceaccount.com" '
        def roles_for($member): [.bindings[] | select(.members | index($member)) | .role] | sort;
        (roles_for($backup) == ["roles/storage.objectCreator"]) and
        (roles_for($restore) == ["roles/storage.objectViewer"])
      '
```

Expected safe result: `true`. The backup account must not receive a viewer/admin role, and restore
must not receive a creator/admin role.

## 7. Verify private routing, registry, and cost controls

Network and subnet:

```bash
gcloud compute networks describe agora-production \
  --project="$WORKLOAD_PROJECT_ID" \
  --format='yaml(name,autoCreateSubnetworks,routingConfig.routingMode,mtu,subnetworks)'
gcloud compute networks subnets describe "agora-production-${REGION}" \
  --project="$WORKLOAD_PROJECT_ID" \
  --region="$REGION" \
  --format='yaml(name,ipCidrRange,privateIpGoogleAccess,stackType,network)'
gcloud compute routes list --project="$WORKLOAD_PROJECT_ID" \
  --filter='network:agora-production' \
  --format='table(name,destRange,nextHopGateway,priority)'
```

Expected safe result: custom mode, regional routing, MTU 1460, the selected `/24`, Private Google
Access enabled, IPv4 only, and exactly the `199.36.153.4/30` and `34.126.0.0/18` routes. No
`0.0.0.0/0` route appears.

Firewall and absence of idle/public network products:

```bash
gcloud compute firewall-rules list --project="$WORKLOAD_PROJECT_ID" \
  --filter='network:agora-production' \
  --format='table(name,direction,priority,sourceRanges,destinationRanges,allowed,denied,targetTags)'
gcloud compute routers list --project="$WORKLOAD_PROJECT_ID" --format='value(name)'
gcloud compute addresses list --project="$WORKLOAD_PROJECT_ID" \
  --format='table(name,addressType,address,subnetwork.basename(),users.basename())'
gcloud compute forwarding-rules list --project="$WORKLOAD_PROJECT_ID" --format='value(name)'
gcloud services list --enabled --project="$WORKLOAD_PROJECT_ID" \
  --filter='config.name=vpcaccess.googleapis.com' --format='value(config.name)'
```

Expected safe result: six named rules with tagged allow priorities 800/810 and a VPC-wide deny
priority 1200 with no target tag; database ingress has only the production subnet, IAP SSH has only
`35.235.240.0/20`, and no public ingress exists. The address list contains exactly the automatically
reserved INTERNAL address preserved for the one database VM and no EXTERNAL address. The router,
forwarding-rule, and VPC Access commands print nothing: no router/NAT, public frontend, or connector
exists.

Private DNS:

```bash
gcloud dns managed-zones list --project="$WORKLOAD_PROJECT_ID" \
  --format='table(name,dnsName,visibility,privateVisibilityConfig.networks.networkUrl)'
for zone in restricted-googleapis private-artifact-registry private-cloud-run; do
  gcloud dns record-sets list --project="$WORKLOAD_PROJECT_ID" --zone="$zone" \
    --format='table(name,type,ttl,rrdatas)'
done
```

Expected safe result: exactly three private zones attached only to `agora-production`; their apex or
wildcard records resolve through the four `restricted.googleapis.com` VIP addresses. End-to-end
resolution is tested later from attached Cloud Run and VM workloads.

Artifact Registry:

```bash
gcloud artifacts repositories describe agora-production \
  --project="$WORKLOAD_PROJECT_ID" --location="$REGION" \
  --format='yaml(name,format,mode,dockerConfig.immutableTags,cleanupPolicyDryRun,cleanupPolicies)'
gcloud artifacts repositories get-iam-policy agora-production \
  --project="$WORKLOAD_PROJECT_ID" --location="$REGION" \
  --flatten='bindings[].members' \
  --format='table(bindings.role,bindings.members)'
```

Expected safe result: Docker standard repository, immutable tags enabled, cleanup dry-run enabled,
receipt/recent keep policies plus old-untagged deletion preview, one release writer, and one database
reader. Runtime service accounts do not receive redundant same-project Cloud Run pull grants.

Quota preferences:

```bash
gcloud quotas preferences list --project="$WORKLOAD_PROJECT_ID" \
  --billing-project="$MANAGEMENT_PROJECT_ID" \
  --format='table(name.segment(-1),service,quotaId,dimensions,quotaConfig.preferredValue,reconciling)'
```

Expected safe result: four `europe-west1` preferences corresponding to Cloud Run CPU 8000 milli-vCPU,
memory 17179869184 bytes, Direct VPC instances 20, and Compute Engine CPUs 4. If any row reports
`reconciling: true`, wait for Google to finish and recheck; do not raise a limit just to clear the
state.

Budget and notification channels:

```bash
gcloud billing budgets list --billing-account="$BILLING_ACCOUNT_ID" \
  --filter='displayName="Agora production infrastructure"' \
  --format='yaml(displayName,amount,budgetFilter,thresholdRules,allUpdatesRule)'
gcloud beta monitoring channels list --project="$WORKLOAD_PROJECT_ID" \
  --filter='displayName:("Agora production cost alerts" OR "Agora production operations alerts")' \
  --format='table(name,type,enabled,verificationStatus,displayName)'
```

Expected safe result: one monthly budget of 60 `$BILLING_CURRENCY_CODE` units scoped to the
management and workload project numbers, both current-spend and forecasted-spend thresholds at
50/75/90/100%, and exactly the two enabled email channels. Default billing/project recipients are
disabled; both code-managed channels receive the budget. A budget does not stop spend. If a channel
reports `UNVERIFIED`, it is non-functioning: use Google Cloud
Console **Monitoring → Alerting → Edit notification channels** or the documented
[verification API](https://cloud.google.com/monitoring/alerts/using-channels-api), verify the same
code-managed channel, then rerun the list command. Do not create a duplicate channel manually.

Monitoring policies:

```bash
gcloud monitoring policies list --project="$WORKLOAD_PROJECT_ID" \
  --filter='displayName:Agora' \
  --format='table(displayName,enabled,severity)'
```

Expected safe result: eight enabled policies. Five cover database CPU/memory/disk, one covers
PostgreSQL recovery jobs, one covers Authentication 5xx, and one covers application jobs/key
rotation. The low-frequency Authentication/dependency check belongs to the existing `production
drift` workflow so probes cannot keep the instance-billed service continuously allocated. It stays
off while `PRODUCTION_RELEASES_ENABLED` is false; follow
[Respond to production alerts](./respond-to-alerts.md#authentication-synthetic-health) after launch.

Logging:

```bash
gcloud logging buckets describe _Default --location=global \
  --project="$WORKLOAD_PROJECT_ID" \
  --format='yaml(name,retentionDays,locked,analyticsEnabled)'
gcloud logging exclusions describe successful-cloud-run-healthchecks \
  --project="$WORKLOAD_PROJECT_ID" \
  --format='yaml(name,disabled,filter)'
```

Expected safe result: 30-day retention, unlocked, analytics disabled, and an enabled exclusion that
matches only `run.googleapis.com/requests`, `/v2/ping` or `/v2/healthcheck`, and HTTP 2xx/3xx. It
must not exclude failed health checks, application logs, or audit logs.

Continue with [Operate the private PostgreSQL host](./operate-postgresql-host.md). Run its host
selection, foundation-state, firewall, alert, and disabled-manifest IAP checks. Expected safe result:
one private stateful VM, one mounted preserved disk, no database containers, and no public path. Do
not enable a database release during foundation provisioning.

## 8. Remove temporary creation authority

Run only after the protected post-apply plan reports zero change, sections 6–7 pass, and the
database-host runbook confirms the idle host. Removing
authority earlier can strand a partially configured project.

Read the organization ancestor and effective policies before requesting any new authority:

```bash
gcloud projects get-ancestors "$WORKLOAD_PROJECT_ID" \
  --format='table(type,id)'

POLICY_ORGANIZATION_ID="$(gcloud projects get-ancestors "$WORKLOAD_PROJECT_ID" \
  --filter='type=organization' --format='value(id)')"
MISSING_ORG_POLICY_COUNT=0

for constraint in \
  iam.automaticIamGrantsForDefaultServiceAccounts \
  iam.disableServiceAccountKeyCreation \
  iam.disableServiceAccountKeyUpload; do
  if gcloud resource-manager org-policies describe \
    "constraints/${constraint}" \
    --project="$WORKLOAD_PROJECT_ID" \
    --effective --format=json \
    | jq -e '.booleanPolicy.enforced == true' >/dev/null; then
    printf 'ENFORCED %s\n' "$constraint"
  else
    printf 'MISSING  %s\n' "$constraint"
    MISSING_ORG_POLICY_COUNT=$((MISSING_ORG_POLICY_COUNT + 1))
  fi
done

printf 'Missing organization policies: %s\n' "$MISSING_ORG_POLICY_COUNT"
```

An empty `POLICY_ORGANIZATION_ID` selects the standalone controls below. For an
organization-backed project with a nonzero missing count, an organization IAM administrator
temporarily grants the human operator Organization Policy Administrator:

```bash
test -n "$POLICY_ORGANIZATION_ID"
test "$MISSING_ORG_POLICY_COUNT" -gt 0
gcloud organizations add-iam-policy-binding "$POLICY_ORGANIZATION_ID" \
  --member="$OPERATOR_PRINCIPAL" \
  --role='roles/orgpolicy.policyAdmin' \
  --condition=None
```

After the grant propagates, the operator applies only missing policies. The explicit exit capture
ensures one failed update does not skip removal of the temporary organization-wide role:

```bash
POLICY_UPDATE_EXIT=0

for constraint in \
  iam.automaticIamGrantsForDefaultServiceAccounts \
  iam.disableServiceAccountKeyCreation \
  iam.disableServiceAccountKeyUpload; do
  if ! gcloud resource-manager org-policies describe \
    "constraints/${constraint}" \
    --project="$WORKLOAD_PROJECT_ID" \
    --effective --format=json \
    | jq -e '.booleanPolicy.enforced == true' >/dev/null; then
    gcloud resource-manager org-policies enable-enforce \
      "$constraint" \
      --project="$WORKLOAD_PROJECT_ID" \
      || POLICY_UPDATE_EXIT=$?
  fi
done

printf 'Policy update exit: %s\n' "$POLICY_UPDATE_EXIT"
```

The organization IAM administrator removes that grant whether the update succeeded or failed:

```bash
gcloud organizations remove-iam-policy-binding "$POLICY_ORGANIZATION_ID" \
  --member="$OPERATOR_PRINCIPAL" \
  --role='roles/orgpolicy.policyAdmin' \
  --condition=None
```

Rerun the effective-policy loop above. All three lines must read `ENFORCED` and the missing count
must be zero; if the update block ran, `POLICY_UPDATE_EXIT` must also be zero. Propagation can take
several minutes. The code-managed `DEPRIVILEGE` action removes any primitive role granted before
the first constraint took effect. For a standalone project, record that shape and rely on
deprivileging, the all-account zero-key verification in section 6, short-lived Workload Identity
Federation, and periodic zero-key verification. Do not create an organization only to gain these
policies.

Remove only the automatically granted foundation Owner binding:

```bash
gcloud projects remove-iam-policy-binding "$WORKLOAD_PROJECT_ID" \
  --member="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --role='roles/owner' \
  --condition=None
```

Remove the one-time Billing Account User grant; retain Costs Manager for code-managed budgets:

```bash
gcloud billing accounts remove-iam-policy-binding "$BILLING_ACCOUNT_ID" \
  --member="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --role='roles/billing.user' \
  --format=none
```

Remove the parent Project Creator binding when the organization/folder path was used:

```bash
if [[ -n "$FOLDER_ID" ]]; then
  gcloud resource-manager folders remove-iam-policy-binding "$FOLDER_ID" \
    --member="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
    --role='roles/resourcemanager.projectCreator' \
    --condition=None
elif [[ -n "$ORGANIZATION_ID" ]]; then
  gcloud organizations remove-iam-policy-binding "$ORGANIZATION_ID" \
    --member="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
    --role='roles/resourcemanager.projectCreator' \
    --condition=None
fi
```

Verify the cleanup:

```bash
gcloud projects get-iam-policy "$WORKLOAD_PROJECT_ID" \
  --format=json \
| jq -r '
    .bindings[]
    | select(.role == "roles/owner" or .role == "roles/editor")
    | .role as $role
    | .members[]
    | select(startswith("serviceAccount:"))
    | [$role, .]
    | @tsv
  '
gcloud billing accounts get-iam-policy "$BILLING_ACCOUNT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.members=serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --format='value(bindings.role)'
```

Expected safe result: the primitive-role audit prints nothing and the billing command prints only
`roles/billing.costsManager`. Recheck the chosen parent with section 2's command; it must print
nothing. Independently verify the plan identity still has exactly `roles/billing.viewer`. Exact
workload-project roles and the custom metadata role remain code-managed.

Publish the verified workload project for later runbooks:

```bash
gh variable set GCP_WORKLOAD_PROJECT_ID \
  --repo "$REPOSITORY" --body "$WORKLOAD_PROJECT_ID"
test "$(gh variable get GCP_WORKLOAD_PROJECT_ID --repo "$REPOSITORY")" = "$WORKLOAD_PROJECT_ID"
```

Record only the reviewed commit, workflow run URL, opaque plan checksum, project number, verification
timestamp, and successful/failed checklist in the private deployment receipt. Do not record IAM
policy dumps, billing account IDs, email addresses, secrets, or plan values.

## Partial-failure recovery

### Project exists but apply failed

Freeze every foundation writer and keep the project. Inspect the protected run's sanitized resource
types and Google audit logs. Common new-project API propagation delays are resolved by waiting and
creating a fresh reviewed plan; never disable deletion protection, add Owner broadly, or delete the
project to retry. The new plan must converge the same desired state and contain no managed-resource
delete, replacement, or forget action.

### Standalone project exists but foundation state does not own it

Do not plan creation again and do not run a local import. Keep the empty project, verify its numeric
ID and billing link, and use only the protected workflow's one-time adoption path. The import target
is exactly `google_project.workload` and the import ID is exactly the chosen project ID. After import,
review a fresh saved plan before applying any other resource.

### State owns the project but Google reports it missing

Stop all writers and treat this as an incident. Google project IDs cannot be reused. Recover state
only if state itself is damaged; otherwise choose a new workload project ID in reviewed code, regrant
temporary parent/billing creation authority, and follow the rebuild procedure when it exists. Never
remove the missing project from state merely to make a plan green.

### Quota metric discovery or preference fails

Do not hardcode a guessed provider quota ID. Ask the operator for these non-secret listings and
compare Google's current metric and quota IDs with `cost.tf`:

```bash
gcloud quotas info list --service=run.googleapis.com --project="$WORKLOAD_PROJECT_ID" \
  --billing-project="$MANAGEMENT_PROJECT_ID" \
  --format='table(metric,quotaId,dimensions)'
gcloud quotas info list --service=compute.googleapis.com --project="$WORKLOAD_PROJECT_ID" \
  --billing-project="$MANAGEMENT_PROJECT_ID" \
  --format='table(metric,quotaId,dimensions)'
```

Update code and mocked tests when Google renamed a metric. If a requested ceiling is below live
usage, reduce the workload first; never enable the below-usage safety bypass.

### Budget, monitoring, or notification verification fails

The workload can spend or fail even when alerts fail. Freeze further resource creation, correct the
exact email or policy in code/GitHub, reconcile through a reviewed foundation plan, and verify the
existing channel. Follow the alert runbook; do not add default billing recipients, Pub/Sub,
webhooks, a custom metric, or another alerting product as an emergency workaround unless a separate
design requires it.

### Temporary Owner was removed too early

An authorized human project Owner may restore `roles/owner` only to the exact foundation service
account for the shortest recovery window. Record the incident, finish the exact IAM plan, rerun every
verification, then remove Owner again. Never grant Owner to the release, plan, recovery, runtime, or
GitHub principal directly.

### An unexpected public or fixed-cost network resource exists

Freeze writers and identify its creator from Cloud Audit Logs. Do not delete it ad hoc if OpenTofu
state might own it. A reviewed foundation change must remove or import/reconcile it, and the protected
destruction gate must be deliberate. The database group's one stateful internal address is expected.
No service deployment proceeds until routers/NAT, connectors, external addresses, forwarding rules,
and public database paths are absent again.

## References

- [Creating and managing projects](https://cloud.google.com/resource-manager/docs/creating-managing-projects)
- [Project IAM access and automatic creator Owner](https://cloud.google.com/resource-manager/docs/access-control-proj)
- [Cloud Billing roles](https://cloud.google.com/billing/docs/how-to/billing-access)
- [Configure Private Google Access](https://cloud.google.com/vpc/docs/configure-private-google-access)
- [Service account security best practices](https://cloud.google.com/iam/docs/best-practices-service-accounts)
- [Cloud Run job tags](https://cloud.google.com/run/docs/configuring/jobs/tags)
- [IAM conditions with Resource Manager tags](https://cloud.google.com/iam/docs/conditions-resource-attributes#resource_tags)
- [Default Compute Engine service accounts](https://cloud.google.com/compute/docs/access/service-accounts)
- [Organization policies for service accounts](https://cloud.google.com/resource-manager/docs/organization-policy/restricting-service-accounts)
- [Direct VPC egress and tag limitations](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc)
- [Cloud DNS private zones](https://cloud.google.com/dns/docs/zones/zones-overview)
- [Artifact Registry immutable tags](https://cloud.google.com/artifact-registry/docs/docker/immutable-image-tags)
- [Artifact Registry cleanup policies](https://cloud.google.com/artifact-registry/docs/repositories/cleanup-policy)
- [Cloud Quotas OpenTofu support](https://cloud.google.com/docs/quotas/terraform-support-for-cloud-quotas)
- [Budgets and alerts](https://cloud.google.com/billing/docs/how-to/budgets)
- [Alerting policies](https://cloud.google.com/monitoring/alerts)
- [Notification channels](https://cloud.google.com/monitoring/support/notification-options)
- [Logging exclusions](https://cloud.google.com/logging/docs/exclusions)
- [Cloud Run instance-based billing](https://cloud.google.com/run/docs/configuring/billing-settings)
- [GitHub scheduled workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)
- [Production cost worksheet](../costs/production.md)
