# Provision and verify the workload foundation

Use this runbook to prepare, provision, and independently verify the replaceable production workload
project and its private foundation. It covers project parent and billing authority, protected GitHub
inputs, project adoption, private routing, runtime identities, Artifact Registry, cost controls, and
the idle private PostgreSQL host, daily snapshots, recovery IAM/alerting, and removal of temporary
broad access.

## Current stop condition

Do not execute any mutating command in this runbook yet. The repository defines the resources but
does not contain `.github/workflows/foundation.yaml`; merging and local validation create nothing.
Resource creation requires all of the following:

1. the management-plane bootstrap is applied, migrated to remote state, and independently verified;
2. the protected foundation workflow exists on `master` and authenticates through its exact WIF
   provider;
3. `production-foundation` requires a reviewer, disallows administrator bypass, and accepts only
   protected `master` deployments;
4. a maintainer explicitly authorizes the initial workload-project creation;
5. the protected workflow updates this runbook with its exact dispatch command and saved-plan review
   procedure.

Agents never run `gcloud`, `tofu apply`, or the one-time import. Operators must not substitute a local
OpenTofu apply: it would bypass protected approval, remote plan custody, log sanitization, and the
root-specific automation identity.

## Result and non-result

The completed procedure creates:

- one workload project linked to the selected billing account;
- thirteen workload APIs, one custom VPC, one regional `/24` subnet, two restricted Google API routes,
  six firewall rules, and three private DNS zones;
- six keyless runtime identities, eleven exact cross-project secret IAM bindings, and separate
  create-only backup/read-only restore bucket IAM;
- deprivileged default Google service accounts so none retains a primitive project role;
- one immutable regional Docker repository and narrow release/database access;
- one pinned Shielded COS template, one continuously running `e2-medium` in a stateful one-member
  group, one 20 GiB replaceable boot disk, one 50 GiB preserved balanced data disk, and one
  stateful internal address with a daily `europe-west1` snapshot schedule and seven-day retention;
- four regional quota preferences, one two-project alert-only budget of 60 units in the billing
  account currency, one email channel, five database capacity alerts, one failed-or-missing-recovery
  alert, 30-day default logging, and one narrow successful-healthcheck exclusion.

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
- The cost-alert address is monitored by a human. If it is a group, it accepts messages from Google
  Cloud Quotas, Cloud Billing, and Cloud Monitoring.
- Select at least one named database operator as a `user:` or `group:` IAM member. This identity
  receives privileged OS Login through IAP and must use MFA. A cross-organization operator also
  needs OS Login External User from its own organization administrator.
- The first foundation pull request and its complete sanitized plan have been reviewed. No change
  targets an unrelated project, parent, billing account, network, or secret container.

## 1. Collect and validate non-payload inputs

Start a fresh Bash shell with history expansion and tracing disabled. The prompts avoid recording
values in shell history. These identifiers are configuration, not application secret payloads, but
the billing ID and personal email still stay out of public logs.

```bash
set -euo pipefail
set +x

REPOSITORY='a-novel/infra'
REGION='europe-west1'
DATABASE_ZONE='europe-west1-b'
SUBNET_CIDR='10.20.0.0/24'
WORKLOAD_PROJECT_NAME='Agora production'

read -r -p 'Management project ID: ' MANAGEMENT_PROJECT_ID
read -r -p 'New workload project ID: ' WORKLOAD_PROJECT_ID
read -r -p 'Billing account ID (XXXXXX-XXXXXX-XXXXXX): ' BILLING_ACCOUNT_ID
read -r -p 'Cost-alert and quota-contact email address: ' COST_ALERT_EMAIL
read -r -p 'Database operator IAM member (user: or group:): ' DATABASE_OPERATOR_PRINCIPAL
read -r -p 'Organization ID, or blank: ' ORGANIZATION_ID
read -r -p 'Folder ID, or blank: ' FOLDER_ID

FOUNDATION_SERVICE_ACCOUNT="infra-foundation@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com"

[[ "$MANAGEMENT_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$WORKLOAD_PROJECT_ID" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
[[ "$MANAGEMENT_PROJECT_ID" != "$WORKLOAD_PROJECT_ID" ]]
[[ "$BILLING_ACCOUNT_ID" =~ ^[0-9A-Z]{6}-[0-9A-Z]{6}-[0-9A-Z]{6}$ ]]
[[ "$COST_ALERT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
[[ "$DATABASE_ZONE" == "${REGION}-"* ]]
[[ "$DATABASE_OPERATOR_PRINCIPAL" =~ ^(user|group):[^[:space:]@]+@[^[:space:]@]+$ ]]
[[ -z "$ORGANIZATION_ID" || "$ORGANIZATION_ID" =~ ^[0-9]+$ ]]
[[ -z "$FOLDER_ID" || "$FOLDER_ID" =~ ^[0-9]+$ ]]
[[ -z "$ORGANIZATION_ID" || -z "$FOLDER_ID" ]]

DATABASE_OPERATOR_PRINCIPALS="$(
  jq -cn --arg principal "$DATABASE_OPERATOR_PRINCIPAL" '[$principal]'
)"

printf 'Repository: %s\nManagement project: %s\nWorkload project: %s\nRegion: %s\nDatabase zone: %s\nSubnet: %s\n' \
  "$REPOSITORY" "$MANAGEMENT_PROJECT_ID" "$WORKLOAD_PROJECT_ID" "$REGION" "$DATABASE_ZONE" "$SUBNET_CIDR"
```

Expected safe result: the final six non-sensitive selections print, all validations exit zero, and
at most one parent ID is populated. Do not print the billing account, alert address, operator
principal, or JSON principal set.

Verify the active identities and stable bootstrap resources without changing anything:

```bash
gcloud auth list --filter=status:ACTIVE --format='table(account,status)'
gh auth status

gcloud projects describe "$MANAGEMENT_PROJECT_ID" \
  --format='yaml(projectId,projectNumber,lifecycleState)'
MANAGEMENT_PROJECT_NUMBER="$(gcloud projects describe "$MANAGEMENT_PROJECT_ID" --format='value(projectNumber)')"
[[ "$MANAGEMENT_PROJECT_NUMBER" =~ ^[0-9]+$ ]]
BACKUP_BUCKET_NAME="${MANAGEMENT_PROJECT_ID}-${MANAGEMENT_PROJECT_NUMBER}-backups"
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

Confirm the workload ID is unused before authorizing creation:

```bash
if gcloud projects describe "$WORKLOAD_PROJECT_ID" --format='value(projectId)' >/dev/null 2>&1; then
  printf 'STOP: project ID already exists; choose the adoption path or a different ID.\n' >&2
  exit 1
fi
printf 'Project ID is not visible to the active operator.\n'
```

An inaccessible project can produce the same result as an unused ID. The first protected plan is the
authoritative creation attempt; never weaken IAM or guess around an `ALREADY_EXISTS` response.

## 2. Choose exactly one project-parent path

### Organization or folder path (preferred when one already exists)

Do not buy or create an organization solely for this deployment. When an organization/folder exists,
grant project creation only at the narrowest selected parent. These commands are mutating and remain
blocked by the current stop condition.

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
production VPC is created. The future workflow owns that one-time adoption; do not run `tofu import`
or delete the default VPC from a local checkout. If the workflow does not yet expose this reviewed
path, stop here.

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
are mutating and remain blocked by the current stop condition.

```bash
gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT_ID" \
  --member="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --role='roles/billing.user' \
  --condition=None
gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT_ID" \
  --member="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --role='roles/billing.costsManager' \
  --condition=None
```

Verify without dumping the rest of the billing policy:

```bash
gcloud billing accounts get-iam-policy "$BILLING_ACCOUNT_ID" \
  --flatten='bindings[].members' \
  --filter="bindings.members=serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}" \
  --format='table(bindings.role,bindings.members)'
```

Expected safe result: exactly `roles/billing.costsManager` and `roles/billing.user`. The latter is
removed after first convergence; Costs Manager remains so later reviewed budget edits work.

## 4. Store the future protected-workflow inputs

The `production-foundation` environment must already have the protections established by the
bootstrap runbook. Verify them before writing values:

```bash
gh api "repos/${REPOSITORY}/environments/production-foundation" \
  --jq '{name,protected_branches:.deployment_branch_policy.protected_branches,custom_branch_policies:.deployment_branch_policy.custom_branch_policies,reviewers:[.protection_rules[]? | select(.type=="required_reviewers") | .reviewers[].reviewer.login]}'
```

Expected safe result: the environment name is exact, protected branches are enabled, custom branch
policies are disabled, and the intended independent reviewer appears. Confirm administrator bypass
is disabled in **Repository settings → Environments → production-foundation**; GitHub's public API
does not expose a reliable verification field for that switch.

Store public identifiers as environment variables:

```bash
gh variable set MANAGEMENT_PROJECT_ID --repo "$REPOSITORY" --env production-foundation \
  --body "$MANAGEMENT_PROJECT_ID"
gh variable set WORKLOAD_PROJECT_ID --repo "$REPOSITORY" --env production-foundation \
  --body "$WORKLOAD_PROJECT_ID"
gh variable set WORKLOAD_PROJECT_NAME --repo "$REPOSITORY" --env production-foundation \
  --body "$WORKLOAD_PROJECT_NAME"
gh variable set BACKUP_BUCKET_NAME --repo "$REPOSITORY" --env production-foundation \
  --body "$BACKUP_BUCKET_NAME"
gh variable set REGION --repo "$REPOSITORY" --env production-foundation --body "$REGION"
gh variable set DATABASE_ZONE --repo "$REPOSITORY" --env production-foundation \
  --body "$DATABASE_ZONE"
gh variable set SUBNET_CIDR --repo "$REPOSITORY" --env production-foundation --body "$SUBNET_CIDR"

if [[ -n "$ORGANIZATION_ID" ]]; then
  gh variable set ORGANIZATION_ID --repo "$REPOSITORY" --env production-foundation \
    --body "$ORGANIZATION_ID"
  gh variable delete FOLDER_ID --repo "$REPOSITORY" --env production-foundation 2>/dev/null || true
elif [[ -n "$FOLDER_ID" ]]; then
  gh variable set FOLDER_ID --repo "$REPOSITORY" --env production-foundation --body "$FOLDER_ID"
  gh variable delete ORGANIZATION_ID --repo "$REPOSITORY" --env production-foundation 2>/dev/null || true
else
  gh variable delete ORGANIZATION_ID --repo "$REPOSITORY" --env production-foundation 2>/dev/null || true
  gh variable delete FOLDER_ID --repo "$REPOSITORY" --env production-foundation 2>/dev/null || true
fi
```

The billing account, notification address, and database operator set are not application secrets,
but environment secrets prevent a public repository from exposing billing metadata, contact
identity, or privileged operator identity. Pass them through stdin instead of process arguments:

```bash
printf '%s' "$BILLING_ACCOUNT_ID" \
  | gh secret set BILLING_ACCOUNT_ID --repo "$REPOSITORY" --env production-foundation
printf '%s' "$COST_ALERT_EMAIL" \
  | gh secret set COST_ALERT_EMAIL --repo "$REPOSITORY" --env production-foundation
printf '%s' "$DATABASE_OPERATOR_PRINCIPALS" \
  | gh secret set DATABASE_OPERATOR_PRINCIPALS --repo "$REPOSITORY" --env production-foundation
```

`COST_ALERT_EMAIL` receives budget notifications and Cloud Quotas review follow-up. It carries no
quota-administration authority; the protected foundation service account owns the code-managed quota
role.

Unset the private values after upload:

```bash
unset BILLING_ACCOUNT_ID COST_ALERT_EMAIL DATABASE_OPERATOR_PRINCIPAL DATABASE_OPERATOR_PRINCIPALS
```

Verify the environment inventory. Variable values are intentionally public identifiers; GitHub does
not return secret values:

```bash
gh variable list --repo "$REPOSITORY" --env production-foundation
gh secret list --repo "$REPOSITORY" --env production-foundation
```

Expected safe result: seven required variables, at most one parent variable, and exactly the three
secret names above. The future workflow maps these names to the matching `TF_VAR_*` inputs and must
mask them before any command. `DATABASE_OPERATOR_PRINCIPALS` is the JSON array consumed by the
OpenTofu set input; its protected plan and state are private. Budget, database capacity, pinned COS
image, and quota defaults remain reviewed code instead of mutable GitHub inputs.

## 5. Protected plan and apply (not available yet)

Stop until the protected foundation workflow lands. That workflow must:

1. authenticate only from `master`, the exact workflow path, and `production-foundation` through the
   `infra-foundation` WIF provider;
2. reconcile the bootstrap root first so `billingbudgets.googleapis.com`,
   `cloudbilling.googleapis.com`, and `cloudquotas.googleapis.com` are enabled in the management
   project; the foundation service account uses that project as its Cloud Quotas billing project;
3. initialize foundation state at the existing `foundation/` managed-folder boundary with locking;
4. for the standalone path only, import the already-created project before the first plan and refuse
   adoption when any other resource is present or state already owns another project;
5. create an opaque saved plan, store it only in private management storage, and print only the
   sanitized action/resource-type summary;
6. fail when the plan deletes, replaces, or forgets any managed resource; the initial plan requires no
   destructive label because it must contain no destructive action;
7. require the environment reviewer to approve the exact unexpired plan, apply that saved plan, and
   prove convergence with a zero-change post-apply plan.

The implementation must replace this stop section with its exact `gh workflow run` and saved-plan
review commands. Until then, there is deliberately no supported apply command.

The expected initial summary contains creates for one project, thirteen APIs, the
network/subnet/routes, six firewalls, three zones and their records, six service accounts, exact
IAM, one repository, one data disk, one immutable instance template, one stateful instance-group
manager, one snapshot policy/attachment, six monitoring alerts, four quota preferences, one
budget/channel, and logging controls. It
contains zero managed-resource delete, replacement, state-forget, Cloud Run service/job, router,
NAT, connector, load balancer, secret-version, or service-account-key actions. For standalone
adoption, the reviewed
`google_project` update also has the documented provider side effect of removing Google's empty
default VPC; no workload may be attached to it. Do not approve a plan that differs without changing
and reviewing the code and this runbook.

## 6. Verify project, billing, APIs, and IAM after apply

Re-enter the section 1 values in a fresh shell. Do not print the billing account or email. Then run:

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

Expected safe result: every configured human operator and
`infra-recovery@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com` appear on all nine secrets.
Authentication also appears only on its DSN, SMTP password, and super-admin password; JSON Keys
appears only on its master key and DSN; database host appears on the four owner/backup passwords;
backup appears only on the two backup passwords. Restore, scheduler, release, plan, and foundation
identities do not appear. This filtered view intentionally omits the operators' separate Secret
Version Manager bindings. Never run
`versions access` as a verification shortcut.

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

Budget and notification channel:

```bash
gcloud billing budgets list --billing-account="$BILLING_ACCOUNT_ID" \
  --filter='displayName="Agora production infrastructure"' \
  --format='yaml(displayName,amount,budgetFilter,thresholdRules,allUpdatesRule)'
gcloud beta monitoring channels list --project="$WORKLOAD_PROJECT_ID" \
  --filter='displayName="Agora production cost alerts"' \
  --format='table(name,type,enabled,verificationStatus,displayName)'
```

Expected safe result: one monthly budget of 60 `$BILLING_CURRENCY_CODE` units scoped to the
management and workload project numbers, current-spend thresholds 50/75/90/100%, one forecasted
100% threshold, and only the enabled email channel. A budget does not stop spend. If the channel
reports `UNVERIFIED`, it is non-functioning: use Google Cloud
Console **Monitoring → Alerting → Edit notification channels** or the documented
[verification API](https://cloud.google.com/monitoring/alerts/using-channels-api), verify the same
code-managed channel, then rerun the list command. Do not create a duplicate channel manually.

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
matches only `run.googleapis.com/requests`, `/v2/healthcheck`, and HTTP 2xx/3xx. It must not exclude
failed health checks, application logs, or audit logs.

Continue with [Operate the private PostgreSQL host](./operate-postgresql-host.md). Run its host
selection, foundation-state, firewall, alert, and disabled-manifest IAP checks. Expected safe result:
one private stateful VM, one mounted preserved disk, no database containers, and no public path. Do
not enable a database release during foundation provisioning.

## 8. Remove temporary creation authority

Run only after the protected post-apply plan reports zero change, sections 6–7 pass, and the
database-host runbook confirms the idle host. Removing
authority earlier can strand a partially configured project.

For an organization-backed workload project, ask an organization-policy administrator—not CI—to
enforce the default-service-account grant and service-account key constraints before removing
temporary Owner. These controls are manual because giving workload automation organization-policy
authority would create a larger risk than the settings protect against.

```bash
gcloud projects get-ancestors "$WORKLOAD_PROJECT_ID" \
  --format='table(type,id)'

for constraint in \
  iam.automaticIamGrantsForDefaultServiceAccounts \
  iam.disableServiceAccountKeyCreation \
  iam.disableServiceAccountKeyUpload; do
  gcloud resource-manager org-policies enable-enforce \
    "$constraint" \
    --project="$WORKLOAD_PROJECT_ID"
done

for constraint in \
  iam.automaticIamGrantsForDefaultServiceAccounts \
  iam.disableServiceAccountKeyCreation \
  iam.disableServiceAccountKeyUpload; do
  gcloud resource-manager org-policies describe \
    "constraints/${constraint}" \
    --project="$WORKLOAD_PROJECT_ID" \
    --effective \
    --format=yaml
done
```

Expected safe result: the ancestor list includes the intended organization and the effective policy
enforces all three boolean constraints. Policy propagation can take several minutes. The
code-managed `DEPRIVILEGE` action removes any primitive role granted before the first constraint took
effect; the policy prevents a future default account from receiving it automatically. If this is a
standalone project, do not create an organization solely for these controls. Record the standalone
shape and rely on that deprivileging action, the all-account zero-key verification in section 6,
short-lived Workload Identity Federation for automation, and periodic zero-key verification.

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
  --condition=None
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
nothing. Exact workload-project roles and the custom metadata role remain code-managed.

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

### Budget or notification verification fails

The workload can spend even when alerts fail. Freeze further resource creation, correct the exact
email in code/GitHub, reconcile through a reviewed foundation plan, and verify the existing channel.
Do not add default billing recipients, Pub/Sub, webhooks, or another alerting product as an emergency
workaround unless a separate design requires it.

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
- [Default Compute Engine service accounts](https://cloud.google.com/compute/docs/access/service-accounts)
- [Organization policies for service accounts](https://cloud.google.com/resource-manager/docs/organization-policy/restricting-service-accounts)
- [Direct VPC egress and tag limitations](https://cloud.google.com/run/docs/configuring/vpc-direct-vpc)
- [Cloud DNS private zones](https://cloud.google.com/dns/docs/zones/zones-overview)
- [Artifact Registry immutable tags](https://cloud.google.com/artifact-registry/docs/docker/immutable-image-tags)
- [Artifact Registry cleanup policies](https://cloud.google.com/artifact-registry/docs/repositories/cleanup-policy)
- [Cloud Quotas OpenTofu support](https://cloud.google.com/docs/quotas/terraform-support-for-cloud-quotas)
- [Budgets and alerts](https://cloud.google.com/billing/docs/how-to/budgets)
- [Logging exclusions](https://cloud.google.com/logging/docs/exclusions)
- [Production cost worksheet](../costs/production.md)
