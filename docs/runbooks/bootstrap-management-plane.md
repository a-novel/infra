# Bootstrap and verify the management plane

This is the one-time, operator-only procedure for creating Agora's stable Google Cloud management
plane, migrating its initial local state into GCS, configuring GitHub's deployment gates, and
removing temporary broad access. It supports both a standalone billing-account project and a project
placed under an existing organization or folder.

Do not run this procedure from a pull-request branch. Do not let an agent run it. Stop after any
unexpected output: every creation command is idempotent only within the state and identifiers
established here, and guessing during bootstrap can create a second root of trust.

Official references: [create a project](https://cloud.google.com/resource-manager/docs/creating-managing-projects),
[link billing](https://cloud.google.com/billing/docs/how-to/modify-project),
[Application Default Credentials](https://cloud.google.com/docs/authentication/provide-credentials-adc),
[GCS backend](https://opentofu.org/docs/language/settings/backends/gcs/),
[GitHub environments](https://docs.github.com/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
and [Google WIF for deployment pipelines](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines).

## Preconditions and stop conditions

An operator needs all of the following:

- a Google user account protected by multi-factor authentication, with recovery codes stored outside
  Google Cloud;
- permission to create a project and link the chosen open billing account;
- for an organization/folder placement, permission to create projects at that parent;
- GitHub admin access to `a-novel/infra` and a second maintainer with at least read access who can
  approve foundation and recovery jobs;
- `gcloud`, `gh`, `jq`, Git, and OpenTofu `1.12.6` installed locally;
- `master` containing this bootstrap change, with all required checks green;
- a private terminal that is not recording, streaming, or running with shell tracing.

The billing account itself cannot be created safely through this repository. If the account list in
the next section is empty, create and fund a billing account in
[Google Cloud Billing](https://console.cloud.google.com/billing), grant the operator Billing Account
User, then restart this runbook. That payment and account-recovery step is intentionally manual.

Stop immediately if any of these are true:

- the checkout is dirty or not on `master`;
- `gcloud auth list` selects a different human than the intended operator;
- the proposed project ID already resolves;
- the plan summary contains a deletion or replacement;
- the GitHub environments permit unprotected branches;
- foundation or recovery has no independent reviewer or still permits admin bypass;
- a service-account user-managed key exists;
- removing temporary broad access makes the final no-change plan fail.

## 1. Prepare a private operator shell

Run from the repository root. The variables contain identifiers only, not payloads, but the strict
shell mode prevents an empty identifier from targeting the wrong resource.

```bash
set -euo pipefail
set +x
umask 077

test "$(git branch --show-current)" = "master"
test -z "$(git status --porcelain)"
git pull --ff-only

test "$(cat .opentofu-version)" = "1.12.6"
tofu version
gcloud version
gh auth status
jq --version
```

Expected safe result: the branch and cleanliness checks print nothing; OpenTofu reports `v1.12.6`;
the other tools report versions; and `gh` reports an authenticated account with admin access to the
repository.

Authenticate the intended Google human both for `gcloud` and for provider-compatible Application
Default Credentials. Neither command creates a service-account key.

```bash
gcloud auth login
gcloud auth application-default login

OPERATOR_EMAIL="$(gcloud config get-value account 2>/dev/null)"
test -n "${OPERATOR_EMAIL}"
OPERATOR_PRINCIPAL="user:${OPERATOR_EMAIL}"

gcloud auth list --filter=status:ACTIVE --format='value(account)'
printf 'OpenTofu operator: %s\n' "${OPERATOR_PRINCIPAL}"
```

Expected safe result: both final lines name the same intended human. Stop if they do not.

## 2. Select billing and the globally unique management-project ID

List only open billing accounts, choose one by its `ACCOUNT_ID`, and verify the choice before
creating a project.

```bash
gcloud billing accounts list \
  --filter='open=true' \
  --format='table(name.basename(),displayName,masterBillingAccount.basename())'

read -r -p 'Billing account ID: ' BILLING_ACCOUNT_ID
test -n "${BILLING_ACCOUNT_ID}"
gcloud billing accounts describe "${BILLING_ACCOUNT_ID}" \
  --format='yaml(name,displayName,open)'
```

Expected safe result: `open: true` and the intended billing account name. An account ID is not a
secret.

Choose a permanent, globally unique project ID. `agora-management-prod` is the preferred base; add a
short organization-specific suffix only if Google reports that it is unavailable. A project ID
cannot be changed later.

```bash
read -r -p 'Permanent management project ID: ' MANAGEMENT_PROJECT_ID
[[ "${MANAGEMENT_PROJECT_ID}" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]

if gcloud projects describe "${MANAGEMENT_PROJECT_ID}" >/dev/null 2>&1; then
  printf 'Stop: project %s already exists or is already visible.\n' "${MANAGEMENT_PROJECT_ID}" >&2
  false
fi
```

Expected safe result: no output and exit status zero. Do not reuse a project created for another
purpose.

## 3. Create exactly one project

First inspect whether the account has an organization hierarchy:

```bash
gcloud organizations list --format='table(name.basename(),displayName)'
```

Choose exactly one of the following shapes.

### Standalone billing-account shape

Use this when the organization list is empty or Agora does not administer an existing organization.
Do not create an organization solely for this early deployment.

```bash
gcloud projects create "${MANAGEMENT_PROJECT_ID}" \
  --name='Agora management'
```

### Existing organization or folder shape

Use an existing parent. List candidates, select the numeric ID, and use either `--folder` or
`--organization`—never both.

```bash
gcloud resource-manager folders list \
  --organization="$(gcloud organizations list --limit=1 --format='value(name.basename())')" \
  --format='table(name.basename(),displayName)'
```

For an existing folder:

```bash
read -r -p 'Existing folder numeric ID: ' MANAGEMENT_FOLDER_ID
[[ "${MANAGEMENT_FOLDER_ID}" =~ ^[0-9]+$ ]]
gcloud projects create "${MANAGEMENT_PROJECT_ID}" \
  --name='Agora management' \
  --folder="${MANAGEMENT_FOLDER_ID}"
```

For an organization with no suitable folder:

```bash
read -r -p 'Existing organization numeric ID: ' MANAGEMENT_ORGANIZATION_ID
[[ "${MANAGEMENT_ORGANIZATION_ID}" =~ ^[0-9]+$ ]]
gcloud projects create "${MANAGEMENT_PROJECT_ID}" \
  --name='Agora management' \
  --organization="${MANAGEMENT_ORGANIZATION_ID}"
```

Expected safe result for the selected command: Google reports project creation. Verify its immutable
number and parent before linking billing:

```bash
MANAGEMENT_PROJECT_NUMBER="$(gcloud projects describe "${MANAGEMENT_PROJECT_ID}" --format='value(projectNumber)')"
[[ "${MANAGEMENT_PROJECT_NUMBER}" =~ ^[0-9]+$ ]]

gcloud projects describe "${MANAGEMENT_PROJECT_ID}" \
  --format='yaml(projectId,projectNumber,name,parent)'
```

The `projectId`, `name`, and optional `parent` must match the choice above. Record the numeric project
number in the private change record; it is non-secret and is later embedded in WIF principal names.

## 4. Link billing and enable only the bootstrap APIs

```bash
gcloud billing projects link "${MANAGEMENT_PROJECT_ID}" \
  --billing-account="${BILLING_ACCOUNT_ID}"

gcloud billing projects describe "${MANAGEMENT_PROJECT_ID}" \
  --format='yaml(projectId,billingAccountName,billingEnabled)'
```

Expected safe result: `billingEnabled: true` and the selected billing account.

Enable the four APIs needed to let OpenTofu manage the full declared API set. OpenTofu enables and
retains the remaining APIs as code.

```bash
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  serviceusage.googleapis.com \
  storage.googleapis.com \
  --project="${MANAGEMENT_PROJECT_ID}"

gcloud auth application-default set-quota-project "${MANAGEMENT_PROJECT_ID}"
```

Expected safe result: the enable command completes without error and the quota-project command names
the management project.

## 5. Establish temporary bootstrap authority

The first apply must create IAM roles and bindings that do not exist yet. Prefer the simple temporary
Owner grant below, then remove it in section 12. This grant is for the named human only; it is never
given to automation and never stored in code.

```bash
gcloud projects add-iam-policy-binding "${MANAGEMENT_PROJECT_ID}" \
  --member="${OPERATOR_PRINCIPAL}" \
  --role='roles/owner' \
  --condition=None
```

If an existing organization policy refuses primitive roles, do not weaken that policy. Instead add
the six future operator roles plus two temporary project-wide data roles:

```bash
for role in \
  roles/iam.roleAdmin \
  roles/iam.serviceAccountAdmin \
  roles/iam.workloadIdentityPoolAdmin \
  roles/logging.configWriter \
  roles/resourcemanager.projectIamAdmin \
  roles/serviceusage.serviceUsageAdmin \
  roles/secretmanager.admin \
  roles/storage.admin
do
  gcloud projects add-iam-policy-binding "${MANAGEMENT_PROJECT_ID}" \
    --member="${OPERATOR_PRINCIPAL}" \
    --role="${role}" \
    --condition=None >/dev/null
done
```

Record which path was used. The fallback's project-wide `secretmanager.admin` and `storage.admin`
grants are removed in section 12; the other six become OpenTofu-managed operator grants.

## 6. Configure the three GitHub environments

The read-only plan/drift identity deliberately has no environment. Create exactly three deployment
environments: routine release is restricted to protected branches; foundation and recovery also
require a different human reviewer and prevent self-review.

```bash
read -r -p 'Second maintainer GitHub login: ' ENVIRONMENT_REVIEWER_LOGIN
test -n "${ENVIRONMENT_REVIEWER_LOGIN}"
test "${ENVIRONMENT_REVIEWER_LOGIN}" != "$(gh api user --jq .login)"

ENVIRONMENT_REVIEWER_ID="$(gh api "users/${ENVIRONMENT_REVIEWER_LOGIN}" --jq .id)"
gh api "repos/a-novel/infra/collaborators/${ENVIRONMENT_REVIEWER_LOGIN}/permission" \
  --jq '{user:.user.login,permission}'
```

Expected safe result: the selected login and at least `read` permission. Then create foundation and
recovery with the same independent reviewer:

```bash
for environment in production-foundation production-recovery; do
  jq -n \
    --argjson reviewer_id "${ENVIRONMENT_REVIEWER_ID}" \
    '{
      wait_timer: 0,
      prevent_self_review: true,
      reviewers: [{type: "User", id: $reviewer_id}],
      deployment_branch_policy: {
        protected_branches: true,
        custom_branch_policies: false
      }
    }' \
  | gh api \
      --method PUT \
      "repos/a-novel/infra/environments/${environment}" \
      --input - \
      --jq '{name,can_admins_bypass,deployment_branch_policy,protection_rules}'
done
```

Create routine release without an approval queue; review already occurs through the protected merge
and release manifest. It still requires a protected branch and its own WIF boundary.

```bash
jq -n \
  '{
    wait_timer: 0,
    prevent_self_review: false,
    reviewers: null,
    deployment_branch_policy: {
      protected_branches: true,
      custom_branch_policies: false
    }
  }' \
| gh api \
    --method PUT \
    repos/a-novel/infra/environments/production-release \
    --input - \
    --jq '{name,can_admins_bypass,deployment_branch_policy,protection_rules}'
```

GitHub's documented REST update does not expose the administrator-bypass switch. For
`production-foundation` and `production-recovery`, open **Repository settings → Environments → the
environment**, clear **Allow administrators to bypass configured protection rules**, and save. This
is the only console-only repository setting in this bootstrap; it is a core security control, not an
infrastructure resource.

Independently verify all three environments:

```bash
gh api repos/a-novel/infra/environments --jq '[.environments[].name] | sort'

for environment in production-foundation production-recovery; do
  gh api "repos/a-novel/infra/environments/${environment}" \
    --jq '{
      name,
      can_admins_bypass,
      deployment_branch_policy,
      required_reviewers: [
        .protection_rules[]
        | select(.type == "required_reviewers")
        | {prevent_self_review,reviewers:[.reviewers[].reviewer.login]}
      ]
    }'
done
```

Expected safe result: exactly the three environment names; foundation and recovery report
`can_admins_bypass: false`, `protected_branches: true`, `prevent_self_review: true`, and the intended
reviewer. Stop before cloud apply if any property differs.

## 7. Create and inspect the initial local plan

No secret payload is an OpenTofu variable. The operator list contains IAM member names only.

```bash
export TF_IN_AUTOMATION=true
export TF_VAR_management_project_id="${MANAGEMENT_PROJECT_ID}"
export TF_VAR_operator_principals="[\"${OPERATOR_PRINCIPAL}\"]"

BOOTSTRAP_TEMP_DIR="$(mktemp -d)"
export TF_DATA_DIR="${BOOTSTRAP_TEMP_DIR}/tofu-data"
BOOTSTRAP_PLAN="${BOOTSTRAP_TEMP_DIR}/bootstrap.tfplan"
BOOTSTRAP_PLAN_JSON="${BOOTSTRAP_TEMP_DIR}/bootstrap.json"

tofu -chdir=bootstrap init -backend=false -input=false
tofu -chdir=bootstrap validate
tofu -chdir=bootstrap test
tofu -chdir=bootstrap plan -input=false -out="${BOOTSTRAP_PLAN}"
tofu -chdir=bootstrap show -json "${BOOTSTRAP_PLAN}" >"${BOOTSTRAP_PLAN_JSON}"
./ops/plan-summary.sh bootstrap "${BOOTSTRAP_PLAN_JSON}"
```

Expected safe result: validation and mocked tests pass; the summary prints only action, resource type,
and count; all actions are creates; and there is no deletion, replacement, resource address, project
ID, email, token, state value, or payload in the summary. The full binary and JSON plans remain in a
mode-`0700` temporary directory and must not be uploaded to GitHub or pasted into an issue.

Review the resource counts against [`bootstrap/README.md`](../../bootstrap/README.md). If the summary
contains an update, replacement, or delete, stop and investigate; this is not a first apply.

## 8. Apply the exact reviewed plan once

Reconfirm that Git did not move after planning, then apply the saved binary plan—not a newly computed
plan.

```bash
test "$(git branch --show-current)" = "master"
test -z "$(git status --porcelain)"
git rev-parse HEAD

tofu -chdir=bootstrap apply -input=false "${BOOTSTRAP_PLAN}"
chmod 600 bootstrap/terraform.tfstate 2>/dev/null || true
```

Expected safe result: OpenTofu reports a successful apply and emits only the non-secret project,
bucket, identity-provider, service-account, prefix, and secret-ID outputs. Record the commit SHA and
the apply completion time in the private operator record.

If the apply fails partway, do not delete or recreate resources with `gcloud`. Preserve
`bootstrap/terraform.tfstate` and the temporary directory, fix only the reported cause, regenerate a
sanitized plan from the same checkout, and resume through OpenTofu. If state was lost after any create
succeeded, stop and prepare explicit imports; do not run a second blind create.

## 9. Verify resources before moving state

Read the output identifiers into shell variables without printing state:

```bash
STATE_BUCKET="$(tofu -chdir=bootstrap output -raw state_bucket_name)"
BACKUP_BUCKET="$(tofu -chdir=bootstrap output -raw backup_bucket_name)"
RECEIPT_BUCKET="$(tofu -chdir=bootstrap output -raw receipt_bucket_name)"

test -n "${STATE_BUCKET}"
test -n "${BACKUP_BUCKET}"
test -n "${RECEIPT_BUCKET}"
```

Verify the three buckets and three state IAM folders:

```bash
for bucket in "${STATE_BUCKET}" "${BACKUP_BUCKET}" "${RECEIPT_BUCKET}"; do
  gcloud storage buckets describe "gs://${bucket}" \
    --format='yaml(name,location,storageClass,publicAccessPrevention,uniformBucketLevelAccess,versioning,softDeletePolicy)'
done

gcloud storage managed-folders list "gs://${STATE_BUCKET}/" --uri | sort
```

Expected safe result: all buckets are `EU`, Standard, uniform-access, and public-access prevention is
enforced; state and receipts have versioning and seven-day soft delete; backups have no soft-delete
retention. Managed-folder output ends in exactly `bootstrap/`, `foundation/`, and `release/`.

Verify the metadata-only secrets and keyless identities:

```bash
gcloud secrets list \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --format='value(name.basename())' \
  | sort

gcloud iam service-accounts list \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --filter='email~"^infra-(plan|foundation|release|recovery)@"' \
  --format='value(email)' \
  | sort
```

Expected safe result: the seven IDs in the bootstrap secret-contract table and exactly four
`infra-*` service-account emails. Secret values do not exist yet and must not be added during this
verification.

## 10. Migrate local state to GCS and prove recovery generations exist

Keep the same `TF_DATA_DIR`; it records that the current backend is local. The migration prompt must
name the new GCS backend and ask to copy the existing state. Read it, then answer `yes`.

```bash
tofu -chdir=bootstrap init \
  -migrate-state \
  -input=true \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config='prefix=bootstrap'
```

Expected safe result: OpenTofu reports successful backend initialization and state migration. Verify
the remote object and use the remote backend to list addresses without exposing values:

```bash
gcloud storage ls --all-versions \
  "gs://${STATE_BUCKET}/bootstrap/default.tfstate"

tofu -chdir=bootstrap state list
```

Expected safe result: at least one URI ending in `bootstrap/default.tfstate#<numeric-generation>` and
a non-empty list of bootstrap resource addresses. Never run `tofu state pull` into a public terminal
or print the state object's contents.

Create a second generation with a no-change remote plan, then inspect only its sanitized summary:

```bash
REMOTE_PLAN="${BOOTSTRAP_TEMP_DIR}/remote-verify.tfplan"
REMOTE_PLAN_JSON="${BOOTSTRAP_TEMP_DIR}/remote-verify.json"

tofu -chdir=bootstrap plan -input=false -out="${REMOTE_PLAN}" >/dev/null
tofu -chdir=bootstrap show -json "${REMOTE_PLAN}" >"${REMOTE_PLAN_JSON}"
./ops/plan-summary.sh bootstrap "${REMOTE_PLAN_JSON}"
```

Expected safe result: only the summary header, because there are no changes. If OpenTofu reports
drift, stop before removing temporary access.

After remote state and the no-change plan are verified, remove only the exact ignored local state
copies. Remote versioned state is the recovery source after this point.

```bash
find bootstrap -maxdepth 1 -type f -name 'terraform.tfstate*' -print
rm -f -- bootstrap/terraform.tfstate bootstrap/terraform.tfstate.backup
```

The first command should name no unexpected path. The second permanently removes only those two
local files; it does not touch remote state.

## 11. Publish non-secret workflow coordinates as GitHub variables

These values are public resource identifiers, not credentials. The repository-level pair selects the
read-only plan identity. Environment-level variables with the same names override it only after the
matching GitHub protection gate passes.

```bash
PLAN_PROVIDER="$(tofu -chdir=bootstrap output -json workload_identity_providers | jq -r .plan)"
PLAN_ACCOUNT="$(tofu -chdir=bootstrap output -json automation_service_accounts | jq -r .plan)"

gh variable set GCP_MANAGEMENT_PROJECT_ID \
  --repo a-novel/infra \
  --body "${MANAGEMENT_PROJECT_ID}"
gh variable set GCP_STATE_BUCKET \
  --repo a-novel/infra \
  --body "${STATE_BUCKET}"
gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER \
  --repo a-novel/infra \
  --body "${PLAN_PROVIDER}"
gh variable set GCP_SERVICE_ACCOUNT \
  --repo a-novel/infra \
  --body "${PLAN_ACCOUNT}"

for boundary in foundation release recovery; do
  case "${boundary}" in
    foundation) environment='production-foundation' ;;
    release) environment='production-release' ;;
    recovery) environment='production-recovery' ;;
  esac

  provider="$(tofu -chdir=bootstrap output -json workload_identity_providers | jq -r --arg boundary "${boundary}" '.[$boundary]')"
  account="$(tofu -chdir=bootstrap output -json automation_service_accounts | jq -r --arg boundary "${boundary}" '.[$boundary]')"

  gh variable set GCP_WORKLOAD_IDENTITY_PROVIDER \
    --repo a-novel/infra \
    --env "${environment}" \
    --body "${provider}"
  gh variable set GCP_SERVICE_ACCOUNT \
    --repo a-novel/infra \
    --env "${environment}" \
    --body "${account}"
done
```

Verify names without treating any value as secret:

```bash
gh variable list --repo a-novel/infra
for environment in production-foundation production-release production-recovery; do
  gh variable list --repo a-novel/infra --env "${environment}"
done

gh api repos/a-novel/infra/actions/secrets --jq .total_count
for environment in production-foundation production-release production-recovery; do
  gh api "repos/a-novel/infra/environments/${environment}/secrets" --jq .total_count
done
```

Expected safe result: the four repository variable names, two identity variables in each environment,
and zero repository/environment secrets. Organization-level secrets outside this repository's
control are not credentials for this design and must not be added as a workaround.

## 12. Verify federation and remove temporary broad access

First prove that all four providers use the canonical audience and exact immutable claims:

```bash
for provider in github-plan github-foundation github-release github-recovery; do
  gcloud iam workload-identity-pools providers describe "${provider}" \
    --project="${MANAGEMENT_PROJECT_ID}" \
    --location=global \
    --workload-identity-pool=github-actions \
    --format=json \
  | jq -e '
      (.oidc.allowedAudiences // [] | length) == 0
      and (.attributeCondition | contains("assertion.repository_owner_id == '\''131281268'\''"))
      and (.attributeCondition | contains("assertion.repository_id == '\''1344262359'\''"))
      and (.attributeCondition | contains("assertion.ref == '\''refs/heads/master'\''"))
    '
done
```

Expected safe result: four `true` values. Inspect the safe condition text separately and confirm each
provider names exactly its workflow and, for foundation/release/recovery, its matching environment:

```bash
gcloud iam workload-identity-pools providers list \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --location=global \
  --workload-identity-pool=github-actions \
  --format='table(name.basename(),attributeCondition)'
```

Confirm no user-managed service-account key exists. Empty output is success:

```bash
for account in infra-plan infra-foundation infra-release infra-recovery; do
  gcloud iam service-accounts keys list \
    --project="${MANAGEMENT_PROJECT_ID}" \
    --iam-account="${account}@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com" \
    --managed-by=user \
    --format='value(name)'
done
```

For an organization-backed project, ask an organization-policy administrator—not CI—to enforce the
two parent security policies. These controls are manual because giving automation organization-policy
authority would be a larger risk than the setting protects against.

```bash
gcloud projects get-ancestors "${MANAGEMENT_PROJECT_ID}" \
  --format='table(type,id)'

gcloud resource-manager org-policies enable-enforce \
  iam.disableServiceAccountKeyCreation \
  --project="${MANAGEMENT_PROJECT_ID}"

gcloud resource-manager org-policies enable-enforce \
  storage.publicAccessPrevention \
  --project="${MANAGEMENT_PROJECT_ID}"

gcloud resource-manager org-policies describe \
  constraints/iam.disableServiceAccountKeyCreation \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --effective \
  --format=yaml

gcloud resource-manager org-policies describe \
  constraints/storage.publicAccessPrevention \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --effective \
  --format=yaml
```

Expected safe result: both effective policies enforce their boolean constraint. Policy propagation
can take several minutes. If the project has no organization, these commands may be unavailable;
record the standalone shape and rely on the enforced per-bucket public-access setting, the absence of
key resources, exact WIF conditions, user-key audit, and periodic zero-key verification. Do not create
an organization only to gain these policies.

Now remove the temporary grant chosen in section 5.

For the temporary Owner path:

```bash
gcloud projects remove-iam-policy-binding "${MANAGEMENT_PROJECT_ID}" \
  --member="${OPERATOR_PRINCIPAL}" \
  --role='roles/owner' \
  --condition=None
```

For the no-primitive fallback, remove only the two temporary project-wide data roles:

```bash
for role in roles/secretmanager.admin roles/storage.admin; do
  gcloud projects remove-iam-policy-binding "${MANAGEMENT_PROJECT_ID}" \
    --member="${OPERATOR_PRINCIPAL}" \
    --role="${role}" \
    --condition=None >/dev/null
done
```

Verify neither the operator nor an `infra-*` service account has Owner or Editor:

```bash
gcloud projects get-iam-policy "${MANAGEMENT_PROJECT_ID}" --format=json \
| jq -e --arg operator "${OPERATOR_PRINCIPAL}" '
    [
      .bindings[]
      | select(.role == "roles/owner" or .role == "roles/editor")
      | .members[]
      | select(. == $operator or test("^serviceAccount:infra-"))
    ]
    | length == 0
  '
```

Expected safe result: `true`.

Finally prove the least-privilege operator can still read remote state and converge the root:

```bash
FINAL_PLAN="${BOOTSTRAP_TEMP_DIR}/final.tfplan"
FINAL_PLAN_JSON="${BOOTSTRAP_TEMP_DIR}/final.json"

tofu -chdir=bootstrap plan -input=false -out="${FINAL_PLAN}" >/dev/null
tofu -chdir=bootstrap show -json "${FINAL_PLAN}" >"${FINAL_PLAN_JSON}"
./ops/plan-summary.sh bootstrap "${FINAL_PLAN_JSON}"
```

Expected safe result: only the summary header. A permission error or resource change means bootstrap
is incomplete; restore the exact temporary grant used earlier, diagnose through the sanitized plan,
and do not enable workflows.

## 13. Verify state locking audit evidence and finish

The remote plans above should have created and removed `bootstrap/default.tflock`. Query only audit
metadata:

```bash
gcloud logging read \
  'resource.type="gcs_bucket" AND resource.labels.bucket_name="'"${STATE_BUCKET}"'" AND protoPayload.resourceName:"bootstrap/default.tflock"' \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --limit=20 \
  --format='table(timestamp,protoPayload.methodName,protoPayload.authenticationInfo.principalEmail)'
```

Expected safe result: recent create/delete object methods for the operator. Audit records contain
identity and resource metadata, never state content or secret payload.

Remove the local full plans and isolated provider directory, then clear identifier variables from the
shell:

```bash
rm -rf -- "${BOOTSTRAP_TEMP_DIR}"
unset TF_DATA_DIR TF_VAR_management_project_id TF_VAR_operator_principals
unset PLAN_PROVIDER PLAN_ACCOUNT BOOTSTRAP_PLAN BOOTSTRAP_PLAN_JSON
unset REMOTE_PLAN REMOTE_PLAN_JSON FINAL_PLAN FINAL_PLAN_JSON
unset STATE_BUCKET BACKUP_BUCKET RECEIPT_BUCKET MANAGEMENT_PROJECT_NUMBER
unset MANAGEMENT_PROJECT_ID BILLING_ACCOUNT_ID OPERATOR_EMAIL OPERATOR_PRINCIPAL
unset ENVIRONMENT_REVIEWER_ID ENVIRONMENT_REVIEWER_LOGIN
```

This permanently removes only the unique temporary directory created in section 7. The remote state,
bucket generations, audit records, and GitHub variables remain.

Bootstrap is complete only when all final checks pass. The next infrastructure task may add protected
workflows, but no workflow should apply foundation or release resources before its WIF exchange,
sanitized plan, exact-plan apply, and environment approval are independently tested.
