# Bootstrap and verify the management plane

> First production run: step 1. Start from the [ordered index](./README.md#first-production-run);
> finish all 13 steps, then continue to workload foundation.

This is the one-time, operator-only procedure for creating Agora's stable Google Cloud management
plane, seeding its protected GCS backend, configuring GitHub's deployment gates, and removing
temporary broad access. It supports both a standalone billing-account project and a project placed
under an existing organization or folder.

Do not run this procedure from a pull-request branch. Do not let an agent run it. Stop after any
unexpected output: every creation command is idempotent only within the state and identifiers
established here, and guessing during bootstrap can create a second root of trust.

Official references: [create a project](https://cloud.google.com/resource-manager/docs/creating-managing-projects),
[link billing](https://cloud.google.com/billing/docs/how-to/modify-project),
[Application Default Credentials](https://cloud.google.com/docs/authentication/provide-credentials-adc),
[create a storage bucket](https://cloud.google.com/sdk/gcloud/reference/storage/buckets/create),
[GCS backend](https://opentofu.org/docs/language/settings/backends/gcs/),
[import existing infrastructure](https://opentofu.org/docs/cli/commands/import/),
[GitHub environments](https://docs.github.com/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
and [Google WIF for deployment pipelines](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines).

## Operator context

The operator selects both stable project IDs before bootstrap. Create `.envrc` once with the root
[project-coordinate setup](../../README.md#choose-the-project-coordinates), then load and validate
it before running later blocks in the existing configured zsh session:

```sh
. ./.envrc
./ops/verify-operator-env.sh
```

The verifier must print `PASS operator project coordinates`. Paste this block once before section 1
to set the private-file mode used by temporary bootstrap artifacts:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
umask 077
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

## Preconditions and stop conditions

An operator needs all of the following:

- a Google user account protected by multi-factor authentication, with recovery codes stored outside
  Google Cloud;
- permission to create a project and link the chosen open billing account;
- for an organization/folder placement, permission to create projects at that parent;
- GitHub admin access to `a-novel/infra`; use a second trusted maintainer with at least read access
  as the foundation and recovery reviewer when one is available, otherwise use the documented
  solo-maintainer exception;
- `gcloud`, `gh`, `jq`, Git, and OpenTofu `1.12.6` installed locally;
- `master` containing this bootstrap change, with all required checks green;
- a private terminal that is not recording, streaming, or running with shell tracing.

The billing account itself cannot be created safely through this repository. If the account list in
the next section is empty, create and fund a billing account in
[Google Cloud Billing](https://console.cloud.google.com/billing), grant the operator Billing Account
User, then restart this runbook. That payment and account-recovery step is intentionally manual.

Stop immediately if any of these are true:

- the checkout is dirty or not on `master`;
- `gcloud config get-value account` names a different human than the intended operator;
- the proposed project ID already resolves;
- the derived state-bucket name already resolves before section 7;
- the plan summary contains a deletion, replacement, or state-forget action;
- the GitHub environments permit unprotected branches;
- foundation or recovery has no required reviewer, permits admin bypass, or allows self-review
  outside the documented solo-maintainer exception;
- a service-account user-managed key exists;
- removing temporary broad access makes the final no-change plan fail.

## 1. Verify local tools and authenticate the operator

The ordered index's repository gate already proves that the checkout is clean, current, and on
`master`. When entering this runbook directly, complete
[Start or resume](./README.md#start-or-resume) once before continuing.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
tofu version    # OpenTofu v1.12.6
gcloud version  # Google Cloud SDK <installed version>
gh --version    # gh version <installed version>
jq --version    # jq-<installed version>
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Look for: OpenTofu reports exactly `v1.12.6`; the other three commands print their installed version
and exit successfully. Their versions are not pinned by this repository.

Authenticate the intended Google human once and write the same login to Application Default
Credentials for OpenTofu. This creates no service-account key.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud auth login --update-adc
gcloud config get-value account
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Look for: the final command names the intended human.

Keep that account in the IAM member syntax used by later commands:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
OPERATOR_PRINCIPAL="user:$(gcloud config get-value account 2>/dev/null)"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

## 2. Select billing and the globally unique management-project ID

List the open billing accounts. The assignment below reuses the result directly when exactly one
account is open; if several IDs are returned, replace it with the chosen `ACCOUNT_ID`.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud billing accounts list \
  --filter='open=true' \
  --format='table(name.basename(),displayName,masterBillingAccount.basename())'

BILLING_ACCOUNT_ID="$(gcloud billing accounts list \
  --filter='open=true' --format='value(name.basename())')"
test -n "${BILLING_ACCOUNT_ID}"
gcloud billing accounts describe "${BILLING_ACCOUNT_ID}" \
  --format='yaml(name,displayName,open)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: `open: true` and the intended billing account name. An account ID is not a
secret.

Check the selected management ID. Project IDs are global and cannot be changed later.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
MANAGEMENT_PROJECT_ID="$INFRA_MANAGEMENT_PROJECT_ID"
! gcloud projects describe "${MANAGEMENT_PROJECT_ID}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Look for: `NOT_FOUND` or a permission error. `describe` cannot distinguish a missing project from a
project the active account cannot access, so the create command in the next step is the definitive
availability check. Do not continue when metadata is returned.

## 3. Create exactly one project

First inspect whether the account has an organization hierarchy:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud organizations list --format='table(name.basename(),displayName)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Choose exactly one of the following shapes.

### Standalone billing-account shape

Use this when the organization list is empty or Agora does not administer an existing organization.
Do not create an organization solely for this early deployment.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud projects create "${MANAGEMENT_PROJECT_ID}" \
  --name='Agora management'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

### Existing organization or folder shape

Use an existing parent. List candidates, select the numeric ID, and use either `--folder` or
`--organization`—never both.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud resource-manager folders list \
  --organization="$(gcloud organizations list --limit=1 --format='value(name.basename())')" \
  --format='table(name.basename(),displayName)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

For an existing folder:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
MANAGEMENT_FOLDER_ID='replace-with-folder-id'
[[ "${MANAGEMENT_FOLDER_ID}" =~ ^[0-9]+$ ]]
gcloud projects create "${MANAGEMENT_PROJECT_ID}" \
  --name='Agora management' \
  --folder="${MANAGEMENT_FOLDER_ID}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

For an organization with no suitable folder:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
MANAGEMENT_ORGANIZATION_ID='replace-with-organization-id'
[[ "${MANAGEMENT_ORGANIZATION_ID}" =~ ^[0-9]+$ ]]
gcloud projects create "${MANAGEMENT_PROJECT_ID}" \
  --name='Agora management' \
  --organization="${MANAGEMENT_ORGANIZATION_ID}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result for the selected command: Google reports project creation. Verify its immutable
number and parent before linking billing:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
MANAGEMENT_PROJECT_NUMBER="$(gcloud projects describe "${MANAGEMENT_PROJECT_ID}" --format='value(projectNumber)')"
[[ "${MANAGEMENT_PROJECT_NUMBER}" =~ ^[0-9]+$ ]]

gcloud projects describe "${MANAGEMENT_PROJECT_ID}" \
  --format='yaml(projectId,projectNumber,name,parent)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The `projectId`, `name`, and optional `parent` must match the choice above. Record the numeric project
number in the private change record; it is non-secret and is later embedded in WIF principal names.

## 4. Link billing and enable only the bootstrap APIs

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud billing projects link "${MANAGEMENT_PROJECT_ID}" \
  --billing-account="${BILLING_ACCOUNT_ID}"

gcloud billing projects describe "${MANAGEMENT_PROJECT_ID}" \
  --format='yaml(projectId,billingAccountName,billingEnabled)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: `billingEnabled: true` and the selected billing account.

Enable the four APIs needed to let OpenTofu manage the full declared API set. OpenTofu enables and
retains the remaining APIs as code.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud services enable \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  serviceusage.googleapis.com \
  storage.googleapis.com \
  --project="${MANAGEMENT_PROJECT_ID}"

gcloud auth application-default set-quota-project "${MANAGEMENT_PROJECT_ID}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: the enable command completes without error and the quota-project command names
the management project.

## 5. Establish temporary bootstrap authority

The first apply must create IAM roles and bindings that do not exist yet. Prefer the simple temporary
Owner grant below, then remove it in section 12. This grant is for the named human only; it is never
given to automation and never stored in code.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud projects add-iam-policy-binding "${MANAGEMENT_PROJECT_ID}" \
  --member="${OPERATOR_PRINCIPAL}" \
  --role='roles/owner' \
  --condition=None
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

If an existing organization policy refuses primitive roles, keep that policy and add the six
future operator roles plus two temporary project-wide data roles:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
for role in \
  roles/iam.roleAdmin \
  roles/iam.serviceAccountAdmin \
  roles/iam.workloadIdentityPoolAdmin \
  roles/logging.privateLogViewer \
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
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Record which path was used. The fallback's project-wide `secretmanager.admin` and `storage.admin`
grants are removed in section 12; the other six become OpenTofu-managed operator grants.

## 6. Configure the three GitHub environments and disabled release switch

The read-only plan/drift identity deliberately has no environment. Create exactly three deployment
environments: routine release is restricted to protected branches; foundation and recovery also
require manual approval and reject administrator bypass.

Use one reviewer setup below. Prefer an independent reviewer whenever a second trusted maintainer is
available.

For two or more maintainers, set the other maintainer as reviewer and prevent self-review:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
ENVIRONMENT_REVIEWER_LOGIN='replace-with-github-login'
PREVENT_SELF_REVIEW=true
test "${ENVIRONMENT_REVIEWER_LOGIN}" != "$(gh api user --jq .login)"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

For a sole maintainer, use the current GitHub user and permit that user to approve the waiting job:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
ENVIRONMENT_REVIEWER_LOGIN="$(gh api user --jq .login)"
PREVENT_SELF_REVIEW=false
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Solo mode still prevents an unattended apply and withholds environment credentials until the
operator approves the job. It cannot provide independent review or protect against compromise of
that same account. Switch to the first setup as soon as a second trusted maintainer is available.

Verify the selected reviewer has repository access:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
test -n "${ENVIRONMENT_REVIEWER_LOGIN}"

ENVIRONMENT_REVIEWER_ID="$(gh api "users/${ENVIRONMENT_REVIEWER_LOGIN}" --jq .id)"
gh api "repos/a-novel/infra/collaborators/${ENVIRONMENT_REVIEWER_LOGIN}/permission" \
  --jq '{user:.user.login,permission}'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: the selected login and at least `read` permission. Then create foundation and
recovery with the selected policy:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
for environment in production-foundation production-recovery; do
  jq -n \
    --argjson reviewer_id "${ENVIRONMENT_REVIEWER_ID}" \
    --argjson prevent_self_review "${PREVENT_SELF_REVIEW}" \
    '{
      wait_timer: 0,
      prevent_self_review: $prevent_self_review,
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
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Create routine release without an approval queue; review already occurs through the protected merge
and release manifest. It still requires a protected branch and its own WIF boundary.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
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
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

GitHub's documented REST update does not expose the administrator-bypass switch. For
`production-foundation` and `production-recovery`, open **Repository settings → Environments → the
environment**, clear **Allow administrators to bypass configured protection rules**, and save. This
is the only console-only repository setting in this bootstrap; it is a core security control, not an
infrastructure resource.

Independently verify all three environments:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
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
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: exactly the three environment names; foundation and recovery report
`can_admins_bypass: false`, `protected_branches: true`, the selected reviewer, and the chosen
`prevent_self_review` value (`true` for independent review or `false` for solo mode). Stop before
cloud apply if any property differs.

When a second trusted maintainer becomes available, rerun this section with their login and
`PREVENT_SELF_REVIEW=true`. This updates only the GitHub environment protection; it requires no
cloud apply.

Create the repository-level launch switch in its fail-safe state. This switch prevents an
unbootstrapped manifest merge from entering `production-release`; it does not replace protected
branches, the environment policy, or the exact WIF claim checks.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gh variable set PRODUCTION_RELEASES_ENABLED \
  --repo a-novel/infra --body false
test "$(gh variable get PRODUCTION_RELEASES_ENABLED --repo a-novel/infra)" = false
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: the test prints nothing and succeeds. Only the production deployment runbook
may change this value to `true`, after every launch prerequisite and explicit authorization pass.

## 7. Seed the state backend and inspect the initial plan

The GCS backend requires a bucket that already exists. Create this one bucket with its state
protections, initialize the backend, and import the bucket before planning. OpenTofu manages it from
that point. No secret payload is an OpenTofu variable; the operator list contains IAM member names
only.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
export TF_IN_AUTOMATION=true
export TF_VAR_management_project_id="${MANAGEMENT_PROJECT_ID}"
export TF_VAR_operator_principals="[\"${OPERATOR_PRINCIPAL}\"]"

BOOTSTRAP_TEMP_DIR="$(mktemp -d)"
export TF_DATA_DIR="${BOOTSTRAP_TEMP_DIR}/tofu-data"

STATE_BUCKET="${MANAGEMENT_PROJECT_ID}-${MANAGEMENT_PROJECT_NUMBER}-tofu-state"
! gcloud storage buckets describe "gs://${STATE_BUCKET}"

gcloud storage buckets create "gs://${STATE_BUCKET}" \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --location=EU \
  --default-storage-class=STANDARD \
  --uniform-bucket-level-access \
  --public-access-prevention \
  --soft-delete-duration=7d

gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning

gcloud storage buckets describe "gs://${STATE_BUCKET}" \
  --format='yaml(name,location,default_storage_class,public_access_prevention,uniform_bucket_level_access,versioning_enabled,soft_delete_policy)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: the first lookup reports that the bucket is absent; creation succeeds; and the
final description reports the exact derived name, `EU`, `STANDARD`, enforced public-access
prevention, uniform access, versioning, and seven-day soft delete. Stop if the name already belongs
to any project or any protection differs.

Refresh the repository before creating the local plan:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
git switch master
git pull --ff-only
test -z "$(git status --porcelain)"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Initialize the remote backend and let the mocked tests run before the import changes state:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
tofu -chdir=bootstrap init \
  -reconfigure \
  -input=false \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config='prefix=bootstrap'

tofu -chdir=bootstrap validate
tofu -chdir=bootstrap test

tofu -chdir=bootstrap import \
  -input=false \
  google_storage_bucket.state \
  "${MANAGEMENT_PROJECT_ID}/${STATE_BUCKET}"

tofu -chdir=bootstrap state list

install -d -m 700 "$HOME/.local/state/a-novel-infra"
BOOTSTRAP_PLAN_EXIT=0
./ops/bootstrap-plan.sh plan \
  "$HOME/.local/state/a-novel-infra/bootstrap.tfplan" \
  || BOOTSTRAP_PLAN_EXIT=$?
test "${BOOTSTRAP_PLAN_EXIT}" -eq 2
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: validation and all four mocked tests pass; the state list contains
`google_storage_bucket.state` and no other managed address; and the summary contains one `update` for
`google_storage_bucket`, plus 114 creates across the declared inventory. It prints no resource
address, project ID, email, token, state value, or payload. Exit code `2` confirms that the saved plan
contains changes.
The full binary plan and its mode-`0600` non-secret custody record remain outside the repository;
neither may be uploaded to GitHub or pasted into an issue.

Review the resource counts against [`bootstrap/README.md`](../../bootstrap/README.md). If the summary
contains an update other than the single imported state bucket, or any replacement, delete, or
forget, stop and investigate.

## 8. Apply the exact reviewed plan once

Apply the saved binary plan—not a newly computed plan:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
./ops/bootstrap-plan.sh apply \
  "$HOME/.local/state/a-novel-infra/bootstrap.tfplan"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: custody proves the plan checksum, project, state bucket, and exact unchanged
local/remote `master` commit, consumes the plan before mutation, and reports success. Record the
commit SHA and completion time in the private operator record. State is written directly to the
versioned GCS backend; plan values and apply diagnostics remain private. The consumed binary plan
is removed, while its non-secret checksum/commit record remains marked `consumed: true`.

If the apply fails partway, do not delete resources or repeat the bucket import. The gate names the
failed stage without publishing its diagnostics. Fix the reported cause on `master`, keep the same
variables and remote state, then save a new plan:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
RECOVERY_PLAN_EXIT=0
./ops/bootstrap-plan.sh plan \
  "$HOME/.local/state/a-novel-infra/bootstrap-recovery.tfplan" \
  || RECOVERY_PLAN_EXIT=$?
test "${RECOVERY_PLAN_EXIT}" -eq 2
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Review the new sanitized summary as above, then apply that exact recovery plan:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
./ops/bootstrap-plan.sh apply \
  "$HOME/.local/state/a-novel-infra/bootstrap-recovery.tfplan"
./ops/tofu-gate.sh converge bootstrap "${STATE_BUCKET}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

If state was lost after a create succeeded, stop and prepare explicit imports instead of planning a
second create.

## 9. Verify resources

Read the output identifiers into shell variables without printing state:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
test "$(tofu -chdir=bootstrap output -raw state_bucket_name)" = "${STATE_BUCKET}"
BACKUP_BUCKET="$(tofu -chdir=bootstrap output -raw backup_bucket_name)"
RECEIPT_BUCKET="$(tofu -chdir=bootstrap output -raw receipt_bucket_name)"

test -n "${STATE_BUCKET}"
test -n "${BACKUP_BUCKET}"
test -n "${RECEIPT_BUCKET}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Verify the three buckets plus the state and receipt IAM folders:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
for bucket in "${STATE_BUCKET}" "${BACKUP_BUCKET}" "${RECEIPT_BUCKET}"; do
  gcloud storage buckets describe "gs://${bucket}" \
    --format='yaml(name,location,default_storage_class,public_access_prevention,uniform_bucket_level_access,versioning_enabled,soft_delete_policy,retention_policy,lifecycle_config)'
done

gcloud storage managed-folders list "gs://${STATE_BUCKET}/" --uri | sort
gcloud storage managed-folders list "gs://${RECEIPT_BUCKET}/" --uri | sort
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: all buckets are `EU`, Standard, uniform-access, and public-access prevention is
enforced; state and receipts have versioning and seven-day soft delete; backups have no soft-delete
retention, a seven-day unlocked bucket retention policy, and a 14-day object lifecycle. The backup
policy is locked only after the first successful clean restore through the dedicated recovery
runbook. State-folder output ends in exactly `bootstrap/`, `foundation/`, and `release/`; receipt
output ends in exactly `production/`, `production/success/`, and `recovery/`. The nested success
folder lets recovery read deployable receipts without reading initialization evidence or writing
under the production prefix.

Verify the metadata-only secrets and keyless identities:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud secrets list \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --format='value(name.basename())' \
  | sort

gcloud iam service-accounts list \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --filter='email~"^infra-(plan|foundation|release|recovery)@"' \
  --format='value(email)' \
  | sort
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: the nine IDs in the bootstrap secret-contract table and exactly four
`infra-*` service-account emails. Secret values do not exist yet and must not be added during this
verification.

## 10. Verify the remote backend and absence of local state

The same `TF_DATA_DIR` has used GCS since the bucket import. Verify the remote object and list
addresses without exposing values:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud storage ls --all-versions \
  "gs://${STATE_BUCKET}/bootstrap/default.tfstate"

tofu -chdir=bootstrap state list
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: at least one URI ending in `bootstrap/default.tfstate#<numeric-generation>` and
a non-empty list of bootstrap resource addresses. The addresses include operator IAM members and
secret-container names, so keep this output in the private terminal. Never run `tofu state pull` or
print the state object's contents.

Exercise remote reads and locking with a no-change plan, then inspect only its sanitized summary. A
clean plan does not guarantee a second state generation; Object Versioning records a generation only
when an operation writes the state object.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
./ops/tofu-gate.sh converge bootstrap "${STATE_BUCKET}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: only the summary header followed by `bootstrap is converged.` If OpenTofu
reports drift, stop before removing temporary access.

Confirm that no local state file was created:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
test -z "$(find bootstrap -maxdepth 1 -type f -name 'terraform.tfstate*' -print)"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: the test prints nothing and succeeds. The versioned GCS object is the only
bootstrap state copy.

## 11. Publish exact workflow coordinates and the bootstrap input bundle

Bucket names, provider resource names, and service-account emails are public identifiers, not
credentials. Their exact GitHub variable names are part of the workflows' interface. Do not create
generic aliases: an unexpected variable must remain unused rather than silently overriding another
trust boundary.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
PLAN_PROVIDER="$(tofu -chdir=bootstrap output -json workload_identity_providers | jq -r .plan)"
PLAN_ACCOUNT="$(tofu -chdir=bootstrap output -json automation_service_accounts | jq -r .plan)"

gh variable set GCP_MANAGEMENT_PROJECT_ID \
  --repo a-novel/infra --body "${MANAGEMENT_PROJECT_ID}"
gh variable set GCP_STATE_BUCKET --repo a-novel/infra --body "${STATE_BUCKET}"
gh variable set GCP_BACKUP_BUCKET --repo a-novel/infra --body "${BACKUP_BUCKET}"
gh variable set GCP_RECEIPT_BUCKET --repo a-novel/infra --body "${RECEIPT_BUCKET}"
gh variable set GCP_PLAN_WORKLOAD_IDENTITY_PROVIDER \
  --repo a-novel/infra --body "${PLAN_PROVIDER}"
gh variable set GCP_PLAN_SERVICE_ACCOUNT \
  --repo a-novel/infra --body "${PLAN_ACCOUNT}"

for boundary in foundation release recovery; do
  case "${boundary}" in
    foundation)
      environment='production-foundation'
      variable_prefix='GCP_FOUNDATION'
      ;;
    release)
      environment='production-release'
      variable_prefix='GCP_RELEASE'
      ;;
    recovery)
      environment='production-recovery'
      variable_prefix='GCP_RECOVERY'
      ;;
  esac

  provider="$(tofu -chdir=bootstrap output -json workload_identity_providers \
    | jq -r --arg boundary "${boundary}" '.[$boundary]')"
  account="$(tofu -chdir=bootstrap output -json automation_service_accounts \
    | jq -r --arg boundary "${boundary}" '.[$boundary]')"

  gh variable set "${variable_prefix}_WORKLOAD_IDENTITY_PROVIDER" \
    --repo a-novel/infra --env "${environment}" --body "${provider}"
  gh variable set "${variable_prefix}_SERVICE_ACCOUNT" \
    --repo a-novel/infra --env "${environment}" --body "${account}"
done
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The protected bootstrap workflow needs the same identifiers used for the first local apply. Put the
complete JSON document in an environment secret so GitHub masks it as one value and the workflow can
materialize it with mode `0600`. It contains no secret payload, but it does contain privileged human
IAM member names.

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
BOOTSTRAP_TFVARS_FILE="${BOOTSTRAP_TEMP_DIR}/bootstrap.tfvars.json"
jq -n \
  --arg management_project_id "${MANAGEMENT_PROJECT_ID}" \
  --arg operator_principal "${OPERATOR_PRINCIPAL}" \
  '{
    management_project_id: $management_project_id,
    region: "europe-west1",
    storage_location: "EU",
    operator_principals: [$operator_principal]
  }' >"${BOOTSTRAP_TFVARS_FILE}"

jq -e '
  (.management_project_id | type == "string") and
  (.operator_principals | length >= 1)
' "${BOOTSTRAP_TFVARS_FILE}" >/dev/null

gh secret set BOOTSTRAP_TFVARS_JSON \
  --repo a-novel/infra --env production-foundation \
  <"${BOOTSTRAP_TFVARS_FILE}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Verify names without printing any secret value:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gh variable list --repo a-novel/infra
for environment in production-foundation production-release production-recovery; do
  gh variable list --repo a-novel/infra --env "${environment}"
  gh secret list --repo a-novel/infra --env "${environment}"
done
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result:

- repository variables are exactly `GCP_MANAGEMENT_PROJECT_ID`, `GCP_STATE_BUCKET`,
  `GCP_BACKUP_BUCKET`,
  `GCP_RECEIPT_BUCKET`, `GCP_PLAN_WORKLOAD_IDENTITY_PROVIDER`,
  `GCP_PLAN_SERVICE_ACCOUNT`, and the false `PRODUCTION_RELEASES_ENABLED` launch switch;
- each environment has only its matching two prefixed identity variables;
- `production-foundation` initially has only `BOOTSTRAP_TFVARS_JSON`;
- `production-release` and `production-recovery` initially have no environment secret.

The foundation and release runbooks add `FOUNDATION_TFVARS_JSON` and `RELEASE_CONFIG_JSON` later.
Organization-level secrets outside this repository's control are not credentials for this design and
must not be added as a workaround.

## 12. Verify federation and remove temporary broad access

First prove that all four providers use the canonical audience and exact immutable claims:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
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
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: four `true` values. Inspect the safe condition text separately and confirm each
provider names exactly its workflow and, for foundation/release/recovery, its matching environment:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud iam workload-identity-pools providers list \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --location=global \
  --workload-identity-pool=github-actions \
  --format='table(name.basename(),attributeCondition)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Confirm no project service account has a user-managed key. Enumerating the project instead of naming
the four current accounts keeps this check fail-closed when another account is introduced:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
PROJECT_SERVICE_ACCOUNTS="$(gcloud iam service-accounts list \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --format='value(email)')"
[[ -n "$PROJECT_SERVICE_ACCOUNTS" ]]
while IFS= read -r account_email; do
  USER_KEY_NAMES="$(gcloud iam service-accounts keys list \
    --project="${MANAGEMENT_PROJECT_ID}" \
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
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Read the organization ancestor and the three effective policies before requesting any new
authority:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud projects get-ancestors "${MANAGEMENT_PROJECT_ID}" \
  --format='table(type,id)'

ORGANIZATION_ID="$(gcloud projects get-ancestors "${MANAGEMENT_PROJECT_ID}" \
  --filter='type=organization' --format='value(id)')"
MISSING_ORG_POLICY_COUNT=0

for constraint in \
  iam.disableServiceAccountKeyCreation \
  iam.disableServiceAccountKeyUpload \
  storage.publicAccessPrevention; do
  if gcloud resource-manager org-policies describe \
    "constraints/${constraint}" \
    --project="${MANAGEMENT_PROJECT_ID}" \
    --effective --format=json \
    | jq -e '.booleanPolicy.enforced == true' >/dev/null; then
    printf 'ENFORCED %s\n' "$constraint"
  else
    printf 'MISSING  %s\n' "$constraint"
    MISSING_ORG_POLICY_COUNT=$((MISSING_ORG_POLICY_COUNT + 1))
  fi
done

printf 'Missing organization policies: %s\n' "$MISSING_ORG_POLICY_COUNT"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

An empty `ORGANIZATION_ID` selects the standalone controls below. For an organization-backed
project with a nonzero missing count, an organization IAM administrator temporarily grants the
human operator Organization Policy Administrator:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
test -n "${ORGANIZATION_ID}"
test "$MISSING_ORG_POLICY_COUNT" -gt 0
gcloud organizations add-iam-policy-binding "${ORGANIZATION_ID}" \
  --member="${OPERATOR_PRINCIPAL}" \
  --role='roles/orgpolicy.policyAdmin' \
  --condition=None
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

After that grant propagates, the operator enforces only missing policies. The explicit exit capture
ensures one failed update does not skip removal of the temporary organization-wide role:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
POLICY_UPDATE_EXIT=0

for constraint in \
  iam.disableServiceAccountKeyCreation \
  iam.disableServiceAccountKeyUpload \
  storage.publicAccessPrevention; do
  if ! gcloud resource-manager org-policies describe \
    "constraints/${constraint}" \
    --project="${MANAGEMENT_PROJECT_ID}" \
    --effective --format=json \
    | jq -e '.booleanPolicy.enforced == true' >/dev/null; then
    gcloud resource-manager org-policies enable-enforce \
      "$constraint" \
      --project="${MANAGEMENT_PROJECT_ID}" \
      || POLICY_UPDATE_EXIT=$?
  fi
done

printf 'Policy update exit: %s\n' "$POLICY_UPDATE_EXIT"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

The organization IAM administrator removes that grant whether the update succeeded or failed:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud organizations remove-iam-policy-binding "${ORGANIZATION_ID}" \
  --member="${OPERATOR_PRINCIPAL}" \
  --role='roles/orgpolicy.policyAdmin' \
  --condition=None
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Rerun the effective-policy loop above. All three lines must read `ENFORCED` and the missing count
must be zero; if the update block ran, `POLICY_UPDATE_EXIT` must also be zero. Propagation can take
several minutes. For a standalone project, record that shape and rely on the enforced bucket
settings, exact WIF conditions, and zero-key verification. Do not create an organization only to
gain these policies.

List the operator's current project roles before choosing the section 5 cleanup path:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud projects get-iam-policy "${MANAGEMENT_PROJECT_ID}" --format=json \
| jq -r --arg operator "${OPERATOR_PRINCIPAL}" '
    .bindings[]
    | select(.members | index($operator))
    | .role
  ' \
| sort
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Exactly one temporary shape must appear. The preferred path contains `roles/owner`; the fallback
contains both `roles/secretmanager.admin` and `roles/storage.admin`. Run only its matching cleanup.

If `roles/owner` appears:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud projects remove-iam-policy-binding "${MANAGEMENT_PROJECT_ID}" \
  --member="${OPERATOR_PRINCIPAL}" \
  --role='roles/owner' \
  --condition=None
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

If both fallback data roles appear:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
for role in roles/secretmanager.admin roles/storage.admin; do
  gcloud projects remove-iam-policy-binding "${MANAGEMENT_PROJECT_ID}" \
    --member="${OPERATOR_PRINCIPAL}" \
    --role="${role}" \
    --condition=None >/dev/null
done
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Verify neither the operator nor any service account has Owner or Editor:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud projects get-iam-policy "${MANAGEMENT_PROJECT_ID}" --format=json \
| jq -e --arg operator "${OPERATOR_PRINCIPAL}" '
    [
      .bindings[]
      | select(.role == "roles/owner" or .role == "roles/editor")
      | .members[]
      | select(. == $operator or startswith("serviceAccount:"))
    ]
    | length == 0
  '
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: `true`.

Finally prove the least-privilege operator can still read remote state and converge the root:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
./ops/tofu-gate.sh converge bootstrap "${STATE_BUCKET}"
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: only the summary header followed by `bootstrap is converged.` A permission
error or resource change means bootstrap is incomplete; restore the exact temporary grant used
earlier, diagnose through the sanitized plan, and do not enable workflows.

## 13. Verify state locking audit evidence and finish

The remote plans above should have created and removed `bootstrap/default.tflock`. Query only audit
metadata:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
gcloud logging read \
  'resource.type="gcs_bucket" AND resource.labels.bucket_name="'"${STATE_BUCKET}"'" AND protoPayload.resourceName:"bootstrap/default.tflock"' \
  --project="${MANAGEMENT_PROJECT_ID}" \
  --limit=20 \
  --format='table(timestamp,protoPayload.methodName,protoPayload.authenticationInfo.principalEmail)'
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

Expected safe result: recent create/delete object methods for the operator. Audit records contain
identity and resource metadata, never state content or secret payload.

Remove the local full plans and isolated provider directory, then clear identifier variables from the
shell:

```zsh
() {
setopt local_options err_return pipe_fail
unsetopt err_exit nounset xtrace
rm -rf -- "${BOOTSTRAP_TEMP_DIR}"
unset TF_DATA_DIR TF_VAR_management_project_id TF_VAR_operator_principals
unset PLAN_PROVIDER PLAN_ACCOUNT BOOTSTRAP_PLAN_EXIT BOOTSTRAP_TFVARS_FILE
unset RECOVERY_PLAN_EXIT
unset STATE_BUCKET BACKUP_BUCKET RECEIPT_BUCKET MANAGEMENT_PROJECT_NUMBER
unset MANAGEMENT_PROJECT_ID BILLING_ACCOUNT_ID OPERATOR_PRINCIPAL ORGANIZATION_ID
unset MISSING_ORG_POLICY_COUNT POLICY_UPDATE_EXIT
unset ENVIRONMENT_REVIEWER_ID ENVIRONMENT_REVIEWER_LOGIN PREVENT_SELF_REVIEW
unset BOOTSTRAP_TEMP_DIR
} || print -u2 'STOP: this command block failed; fix the reported error before continuing.'
```

This permanently removes only the unique temporary directory created in section 7. The remote state,
bucket generations, audit records, and GitHub variables remain.

Bootstrap is complete only when all final checks pass. Continue with the
[workload-foundation runbook](./provision-workload-foundation.md). Do not dispatch a foundation or
release apply before its WIF exchange, sanitized summary, exact-plan custody, and environment gate
match the controls described here. Keep `PRODUCTION_RELEASES_ENABLED=false` until the deployment
runbook explicitly enables it.
