#!/bin/bash

# Runs the human-owned workload-foundation tasks without relying on shell state.

set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage:
  $0 configure [configuration options]
  $0 grant [parent options]
  $0 grant-audit-access
  $0 revoke-audit-access
  $0 finish [parent options]

Configuration options:
  --workload-project-name <name>              Default: Agora production
  --region <region>                           Default: INFRA_REGION or europe-west1
  --database-zone <zone>                      Default: INFRA_DATABASE_ZONE or <region>-c
  --subnet-cidr <cidr>                        Default: 10.20.0.0/24
  --cost-alert-email <email>                  Default: INFRA_COST_ALERT_EMAIL or active account
  --operations-alert-email <email>            Default: INFRA_OPERATIONS_ALERT_EMAIL or active account
  --database-operator-principal <principal>   Repeatable; overrides INFRA_DATABASE_OPERATOR_PRINCIPALS
  --auth-initializer-principal <principal>    Repeatable; overrides INFRA_AUTH_INITIALIZER_PRINCIPALS
  --adopt-existing-project

Parent options (choose at most one; default: management-project parent):
  --organization-id <id>
  --folder-id <id>
  --standalone
EOF
    exit 64
}

fail() {
    printf 'FAIL %s\n' "$1" >&2
    exit "${2:-70}"
}

pass() {
    printf 'PASS %s\n' "$1"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "$1 is required" 69
    fi
}

is_email() {
    [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
}

is_principal() {
    [[ "$1" =~ ^(user|group):[^[:space:]@]+@[^[:space:]@]+$ ]]
}

is_private_24_cidr() {
    local first
    local second
    local third
    local fourth

    if ! [[ "$1" =~ ^10\.[0-9]{1,3}\.[0-9]{1,3}\.0/24$ ]]; then
        return 1
    fi
    IFS=. read -r first second third fourth <<<"${1%/24}"
    [ "$first" -eq 10 ] && [ "$second" -le 255 ] &&
        [ "$third" -le 255 ] && [ "$fourth" -eq 0 ]
}

COMMAND="${1:-}"
if [ -z "$COMMAND" ]; then
    usage
fi
shift

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/verify-operator-env.sh" >/dev/null
WORKLOAD_PROJECT_ID="$INFRA_WORKLOAD_PROJECT_ID"
MANAGEMENT_PROJECT_ID="$INFRA_MANAGEMENT_PROJECT_ID"
WORKLOAD_PROJECT_NAME='Agora production'
REGION="${INFRA_REGION:-europe-west1}"
DATABASE_ZONE="${INFRA_DATABASE_ZONE:-}"
SUBNET_CIDR='10.20.0.0/24'
COST_ALERT_EMAIL="${INFRA_COST_ALERT_EMAIL:-}"
OPERATIONS_ALERT_EMAIL="${INFRA_OPERATIONS_ALERT_EMAIL:-}"
ORGANIZATION_ID=''
FOLDER_ID=''
STANDALONE=false
PARENT_OPTION_COUNT=0
CONFIG_ONLY_OPTION_COUNT=0
PROVISION_OPTION_COUNT=0
ADOPT_EXISTING_PROJECT=false
DATABASE_OPERATOR_PRINCIPALS=()
AUTH_INITIALIZER_PRINCIPALS=()

while [ "$#" -gt 0 ]; do
    case "$1" in
        --workload-project-name)
            [ "$#" -ge 2 ] || usage
            WORKLOAD_PROJECT_NAME="$2"
            PROVISION_OPTION_COUNT=$((PROVISION_OPTION_COUNT + 1))
            shift 2
            ;;
        --region)
            [ "$#" -ge 2 ] || usage
            REGION="$2"
            CONFIG_ONLY_OPTION_COUNT=$((CONFIG_ONLY_OPTION_COUNT + 1))
            shift 2
            ;;
        --database-zone)
            [ "$#" -ge 2 ] || usage
            DATABASE_ZONE="$2"
            CONFIG_ONLY_OPTION_COUNT=$((CONFIG_ONLY_OPTION_COUNT + 1))
            shift 2
            ;;
        --subnet-cidr)
            [ "$#" -ge 2 ] || usage
            SUBNET_CIDR="$2"
            CONFIG_ONLY_OPTION_COUNT=$((CONFIG_ONLY_OPTION_COUNT + 1))
            shift 2
            ;;
        --cost-alert-email)
            [ "$#" -ge 2 ] || usage
            COST_ALERT_EMAIL="$2"
            CONFIG_ONLY_OPTION_COUNT=$((CONFIG_ONLY_OPTION_COUNT + 1))
            shift 2
            ;;
        --operations-alert-email)
            [ "$#" -ge 2 ] || usage
            OPERATIONS_ALERT_EMAIL="$2"
            CONFIG_ONLY_OPTION_COUNT=$((CONFIG_ONLY_OPTION_COUNT + 1))
            shift 2
            ;;
        --database-operator-principal)
            [ "$#" -ge 2 ] || usage
            DATABASE_OPERATOR_PRINCIPALS+=("$2")
            CONFIG_ONLY_OPTION_COUNT=$((CONFIG_ONLY_OPTION_COUNT + 1))
            shift 2
            ;;
        --auth-initializer-principal)
            [ "$#" -ge 2 ] || usage
            AUTH_INITIALIZER_PRINCIPALS+=("$2")
            CONFIG_ONLY_OPTION_COUNT=$((CONFIG_ONLY_OPTION_COUNT + 1))
            shift 2
            ;;
        --organization-id)
            [ "$#" -ge 2 ] || usage
            ORGANIZATION_ID="$2"
            PARENT_OPTION_COUNT=$((PARENT_OPTION_COUNT + 1))
            shift 2
            ;;
        --folder-id)
            [ "$#" -ge 2 ] || usage
            FOLDER_ID="$2"
            PARENT_OPTION_COUNT=$((PARENT_OPTION_COUNT + 1))
            shift 2
            ;;
        --standalone)
            STANDALONE=true
            PARENT_OPTION_COUNT=$((PARENT_OPTION_COUNT + 1))
            shift
            ;;
        --adopt-existing-project)
            ADOPT_EXISTING_PROJECT=true
            PROVISION_OPTION_COUNT=$((PROVISION_OPTION_COUNT + 1))
            shift
            ;;
        *)
            usage
            ;;
    esac
done

case "$COMMAND" in
    configure | grant | grant-audit-access | revoke-audit-access | finish) ;;
    *) usage ;;
esac

if [ "$PARENT_OPTION_COUNT" -gt 1 ]; then
    fail 'choose only one project parent' 64
fi
if [ -n "$ORGANIZATION_ID" ] && ! [[ "$ORGANIZATION_ID" =~ ^[0-9]+$ ]]; then
    fail 'organization ID is invalid' 64
fi
if [ -n "$FOLDER_ID" ] && ! [[ "$FOLDER_ID" =~ ^[0-9]+$ ]]; then
    fail 'folder ID is invalid' 64
fi
if ! [[ "$REGION" =~ ^[a-z]+-[a-z]+[0-9]+$ ]]; then
    fail 'region is invalid' 64
fi
if [ -z "$DATABASE_ZONE" ]; then
    DATABASE_ZONE="${REGION}-c"
fi
if [[ "$DATABASE_ZONE" != "${REGION}-"* ]]; then
    fail 'database zone must belong to the selected region' 64
fi
if ! is_private_24_cidr "$SUBNET_CIDR"; then
    fail 'subnet must be a private /24 CIDR' 64
fi
if [ -z "$WORKLOAD_PROJECT_NAME" ] || [ "${#WORKLOAD_PROJECT_NAME}" -gt 30 ] ||
    [[ "$WORKLOAD_PROJECT_NAME" =~ [[:cntrl:]] ]]; then
    fail 'workload project name is invalid' 64
fi
if [ "$COMMAND" != configure ] && [ "$CONFIG_ONLY_OPTION_COUNT" -gt 0 ]; then
    fail 'configuration options are accepted only by configure' 64
fi
if [ "$COMMAND" != configure ] && [ "$COMMAND" != grant ] &&
    [ "$PROVISION_OPTION_COUNT" -gt 0 ]; then
    fail 'project provisioning options are accepted only by configure or grant' 64
fi
if [ "$COMMAND" != configure ] && [ "$COMMAND" != grant ] &&
    [ "$COMMAND" != finish ] && [ "$PARENT_OPTION_COUNT" -gt 0 ]; then
    fail 'parent options are not accepted by this command' 64
fi

for command_name in gh gcloud git jq; do
    require_command "$command_name"
done

export CLOUDSDK_CORE_DISABLE_PROMPTS=1
umask 077

REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPOSITORY='a-novel/infra'
BACKUP_BUCKET_NAME=''
BILLING_ACCOUNT_ID=''
OPERATOR_EMAIL=''
OPERATOR_PRINCIPAL=''
FOUNDATION_SERVICE_ACCOUNT=''
PLAN_SERVICE_ACCOUNT=''
FOUNDATION_MEMBER=''
PLAN_MEMBER=''

require_reviewed_master() {
    local local_sha
    local remote_sha

    if [ "$(git -C "$REPOSITORY_ROOT" branch --show-current)" != master ] ||
        [ -n "$(git -C "$REPOSITORY_ROOT" status --porcelain)" ]; then
        fail 'this mutation requires a clean local master checkout' 65
    fi
    local_sha="$(git -C "$REPOSITORY_ROOT" rev-parse HEAD)"
    remote_sha="$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)"
    if ! [[ "$local_sha" =~ ^[a-f0-9]{40}$ ]] || [ "$local_sha" != "$remote_sha" ]; then
        fail 'local master does not equal remote master' 65
    fi
}

load_management_context() {
    local published_management_project_id

    published_management_project_id="$(gh variable get GCP_MANAGEMENT_PROJECT_ID \
        --repo "$REPOSITORY")"
    if [ "$published_management_project_id" != "$MANAGEMENT_PROJECT_ID" ]; then
        fail 'INFRA_MANAGEMENT_PROJECT_ID does not match GCP_MANAGEMENT_PROJECT_ID'
    fi
    FOUNDATION_SERVICE_ACCOUNT="infra-foundation@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com"
    PLAN_SERVICE_ACCOUNT="infra-plan@${MANAGEMENT_PROJECT_ID}.iam.gserviceaccount.com"
    FOUNDATION_MEMBER="serviceAccount:${FOUNDATION_SERVICE_ACCOUNT}"
    PLAN_MEMBER="serviceAccount:${PLAN_SERVICE_ACCOUNT}"
}

load_backup_context() {
    BACKUP_BUCKET_NAME="$(gh variable get GCP_BACKUP_BUCKET --repo "$REPOSITORY")"
    if ! [[ "$BACKUP_BUCKET_NAME" =~ ^[a-z0-9][a-z0-9._-]{1,221}[a-z0-9]$ ]]; then
        fail 'backup bucket coordinate is invalid'
    fi
}

load_billing_context() {
    BILLING_ACCOUNT_ID="$(gcloud billing projects describe "$MANAGEMENT_PROJECT_ID" \
        --format='value(billingAccountName.basename())')"
    if ! [[ "$BILLING_ACCOUNT_ID" =~ ^[0-9A-Z]{6}-[0-9A-Z]{6}-[0-9A-Z]{6}$ ]]; then
        fail 'management project billing account is invalid'
    fi
}

load_operator_context() {
    OPERATOR_EMAIL="$(gcloud config get-value account 2>/dev/null)"
    if ! is_email "$OPERATOR_EMAIL"; then
        fail 'active Google account is invalid'
    fi
    OPERATOR_PRINCIPAL="user:${OPERATOR_EMAIL}"
}

case "$COMMAND" in
    configure | grant | grant-audit-access | finish)
        require_reviewed_master
        ;;
esac

resolve_parent() {
    local detected_type
    local detected_id
    local parent_project_id="$MANAGEMENT_PROJECT_ID"

    if [ "$PARENT_OPTION_COUNT" -gt 0 ] && [ "$COMMAND" != finish ]; then
        return
    fi

    # Cleanup follows the created project's actual parent. Before creation,
    # configuration inherits the management project's reviewed placement.
    if [ "$COMMAND" = finish ]; then
        parent_project_id="$WORKLOAD_PROJECT_ID"
    fi

    detected_type="$(gcloud projects describe "$parent_project_id" \
        --format='value(parent.type)')"
    detected_id="$(gcloud projects describe "$parent_project_id" \
        --format='value(parent.id)')"

    if [ "$PARENT_OPTION_COUNT" -gt 0 ]; then
        if { [ -n "$ORGANIZATION_ID" ] &&
            [ "$detected_type:$detected_id" = "organization:${ORGANIZATION_ID}" ]; } ||
            { [ -n "$FOLDER_ID" ] &&
                [ "$detected_type:$detected_id" = "folder:${FOLDER_ID}" ]; } ||
            { [ "$STANDALONE" = true ] && [ -z "$detected_type" ] &&
                [ -z "$detected_id" ]; }; then
            return
        fi
        fail 'explicit parent does not match the workload project parent'
    fi

    case "$detected_type" in
        organization)
            ORGANIZATION_ID="$detected_id"
            ;;
        folder)
            FOLDER_ID="$detected_id"
            ;;
        '')
            STANDALONE=true
            ;;
        *)
            fail 'project parent type is unsupported'
            ;;
    esac
}

case "$COMMAND" in
    configure)
        load_management_context
        load_backup_context
        load_billing_context
        load_operator_context
        resolve_parent
        ;;
    grant)
        load_management_context
        load_billing_context
        resolve_parent
        ;;
    grant-audit-access | revoke-audit-access)
        load_operator_context
        ;;
    finish)
        load_management_context
        load_billing_context
        resolve_parent
        ;;
esac

if [ -n "$ORGANIZATION_ID" ] && ! [[ "$ORGANIZATION_ID" =~ ^[0-9]+$ ]]; then
    fail 'derived organization ID is invalid'
fi
if [ -n "$FOLDER_ID" ] && ! [[ "$FOLDER_ID" =~ ^[0-9]+$ ]]; then
    fail 'derived folder ID is invalid'
fi
if [ "$STANDALONE" = true ] && [ "$ADOPT_EXISTING_PROJECT" = false ] &&
    { [ "$COMMAND" = configure ] || [ "$COMMAND" = grant ]; }; then
    fail 'standalone provisioning requires --adopt-existing-project' 64
fi

binding_exists() {
    local policy_json="$1"
    local role="$2"
    local member="$3"

    jq --exit-status --arg role "$role" --arg member "$member" '
      any(.bindings[]?; .role == $role and (.members | index($member) != null))
    ' <<<"$policy_json" >/dev/null
}

unconditional_binding_exists() {
    local policy_json="$1"
    local role="$2"
    local member="$3"

    jq --exit-status --arg role "$role" --arg member "$member" '
      any(.bindings[]?;
        .role == $role and
        (.members | index($member) != null) and
        ((.condition // null) == null)
      )
    ' <<<"$policy_json" >/dev/null
}

configure_foundation() {
    local environment_json
    local database_principals_json
    local initializer_principals_json

    if [ -z "$COST_ALERT_EMAIL" ]; then
        COST_ALERT_EMAIL="$OPERATOR_EMAIL"
    fi
    if [ -z "$OPERATIONS_ALERT_EMAIL" ]; then
        OPERATIONS_ALERT_EMAIL="$OPERATOR_EMAIL"
    fi
    if ! is_email "$COST_ALERT_EMAIL" || ! is_email "$OPERATIONS_ALERT_EMAIL"; then
        fail 'alert email is invalid' 64
    fi
    if [ "${#DATABASE_OPERATOR_PRINCIPALS[@]}" -eq 0 ] &&
        [ -n "${INFRA_DATABASE_OPERATOR_PRINCIPALS:-}" ]; then
        read -r -a DATABASE_OPERATOR_PRINCIPALS <<<"$INFRA_DATABASE_OPERATOR_PRINCIPALS"
    fi
    if [ "${#AUTH_INITIALIZER_PRINCIPALS[@]}" -eq 0 ] &&
        [ -n "${INFRA_AUTH_INITIALIZER_PRINCIPALS:-}" ]; then
        read -r -a AUTH_INITIALIZER_PRINCIPALS <<<"$INFRA_AUTH_INITIALIZER_PRINCIPALS"
    fi
    if [ "${#DATABASE_OPERATOR_PRINCIPALS[@]}" -eq 0 ]; then
        DATABASE_OPERATOR_PRINCIPALS=("$OPERATOR_PRINCIPAL")
    fi
    if [ "${#AUTH_INITIALIZER_PRINCIPALS[@]}" -eq 0 ]; then
        AUTH_INITIALIZER_PRINCIPALS=("$OPERATOR_PRINCIPAL")
    fi
    for principal in "${DATABASE_OPERATOR_PRINCIPALS[@]}" "${AUTH_INITIALIZER_PRINCIPALS[@]}"; do
        if ! is_principal "$principal"; then
            fail 'operator principal is invalid' 64
        fi
    done

    environment_json="$(gh api "repos/${REPOSITORY}/environments/production-foundation")"
    if ! jq --exit-status '
      .name == "production-foundation" and
      .deployment_branch_policy.protected_branches == true and
      .deployment_branch_policy.custom_branch_policies == false and
      any(.protection_rules[]?; .type == "required_reviewers")
    ' <<<"$environment_json" >/dev/null; then
        fail 'production-foundation environment protection is incomplete'
    fi
    pass 'protected foundation environment'

    database_principals_json="$(printf '%s\n' "${DATABASE_OPERATOR_PRINCIPALS[@]}" |
        jq --raw-input --slurp 'split("\n") | map(select(length > 0))')"
    initializer_principals_json="$(printf '%s\n' "${AUTH_INITIALIZER_PRINCIPALS[@]}" |
        jq --raw-input --slurp 'split("\n") | map(select(length > 0))')"

    FOUNDATION_CONFIG_FILE="$(mktemp)"
    cleanup_config() {
        rm -f -- "${FOUNDATION_CONFIG_FILE:-}"
    }
    trap cleanup_config INT TERM EXIT

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
        --argjson database_operator_principals "$database_principals_json" \
        --argjson authentication_initializer_principals "$initializer_principals_json" \
        --arg cost_alert_email "$COST_ALERT_EMAIL" \
        --arg operations_alert_email "$OPERATIONS_ALERT_EMAIL" \
        --argjson adopt_existing_project "$ADOPT_EXISTING_PROJECT" '
          {
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
          }
        ' >"$FOUNDATION_CONFIG_FILE"

    if ! jq --exit-status '
      ((.organization_id == null) or (.folder_id == null)) and
      (.database_operator_principals | length >= 1) and
      (.authentication_initializer_principals | length >= 1) and
      (.adopt_existing_project or (.organization_id != null) or (.folder_id != null))
    ' "$FOUNDATION_CONFIG_FILE" >/dev/null; then
        fail 'generated foundation configuration is invalid'
    fi

    for environment in production-foundation production-recovery; do
        gh secret set FOUNDATION_TFVARS_JSON \
            --repo "$REPOSITORY" --env "$environment" <"$FOUNDATION_CONFIG_FILE"
    done
    cleanup_config
    trap - INT TERM EXIT
    pass 'protected foundation configuration'
}

grant_foundation_access() {
    local project_json
    local project_billing_json
    local actual_parent_type
    local actual_parent_id

    if [ "$ADOPT_EXISTING_PROJECT" = true ] && [ "$STANDALONE" = false ]; then
        project_json="$(gcloud projects describe "$WORKLOAD_PROJECT_ID" --format=json)"
        actual_parent_type="$(jq --raw-output '.parent.type // ""' <<<"$project_json")"
        actual_parent_id="$(jq --raw-output '.parent.id // ""' <<<"$project_json")"
        if ! jq --exit-status --arg project "$WORKLOAD_PROJECT_ID" '
          .projectId == $project and .lifecycleState == "ACTIVE"
        ' <<<"$project_json" >/dev/null ||
            { [ -n "$ORGANIZATION_ID" ] &&
                [ "$actual_parent_type:$actual_parent_id" != "organization:${ORGANIZATION_ID}" ]; } ||
            { [ -n "$FOLDER_ID" ] &&
                [ "$actual_parent_type:$actual_parent_id" != "folder:${FOLDER_ID}" ]; }; then
            fail 'adopted project identity or parent is unexpected'
        fi
        project_billing_json="$(gcloud billing projects describe \
            "$WORKLOAD_PROJECT_ID" --format=json)"
        if jq --exit-status '.billingEnabled == true' \
            <<<"$project_billing_json" >/dev/null &&
            ! jq --exit-status --arg account "billingAccounts/${BILLING_ACCOUNT_ID}" \
                '.billingAccountName == $account' <<<"$project_billing_json" >/dev/null; then
            fail 'adopted project uses a different billing account'
        fi
    fi

    if [ -n "$FOLDER_ID" ]; then
        gcloud resource-manager folders add-iam-policy-binding "$FOLDER_ID" \
            --member="$FOUNDATION_MEMBER" \
            --role=roles/resourcemanager.projectCreator \
            --condition=None --format=none
    elif [ -n "$ORGANIZATION_ID" ]; then
        gcloud organizations add-iam-policy-binding "$ORGANIZATION_ID" \
            --member="$FOUNDATION_MEMBER" \
            --role=roles/resourcemanager.projectCreator \
            --condition=None --format=none
    else
        # A parentless project cannot be created by the service account. Make
        # only the empty project here; OpenTofu still owns every workload.
        if ! project_json="$(gcloud projects describe "$WORKLOAD_PROJECT_ID" \
            --format=json 2>/dev/null)"; then
            gcloud projects create "$WORKLOAD_PROJECT_ID" \
                --name="$WORKLOAD_PROJECT_NAME" --set-as-default=false
            project_json="$(gcloud projects describe "$WORKLOAD_PROJECT_ID" --format=json)"
        fi
        if ! jq --exit-status --arg project "$WORKLOAD_PROJECT_ID" '
          .projectId == $project and .lifecycleState == "ACTIVE" and
          ((.parent // {}) | length == 0)
        ' <<<"$project_json" >/dev/null; then
            fail 'standalone project identity or parent is unexpected'
        fi
        project_billing_json="$(gcloud billing projects describe \
            "$WORKLOAD_PROJECT_ID" --format=json)"
        if jq --exit-status '.billingEnabled == true' \
            <<<"$project_billing_json" >/dev/null; then
            if ! jq --exit-status --arg account "billingAccounts/${BILLING_ACCOUNT_ID}" \
                '.billingAccountName == $account' <<<"$project_billing_json" >/dev/null; then
                fail 'standalone project uses a different billing account'
            fi
        else
            gcloud billing projects link "$WORKLOAD_PROJECT_ID" \
                --billing-account="$BILLING_ACCOUNT_ID" --format=none
        fi
        gcloud projects add-iam-policy-binding "$WORKLOAD_PROJECT_ID" \
            --member="$FOUNDATION_MEMBER" --role=roles/owner \
            --condition=None --format=none
    fi

    if [ "$ADOPT_EXISTING_PROJECT" = true ] && [ "$STANDALONE" = false ]; then
        # Project Creator helps only with a new project. Explicit adoption also
        # needs temporary authority over the project that already exists.
        gcloud projects add-iam-policy-binding "$WORKLOAD_PROJECT_ID" \
            --member="$FOUNDATION_MEMBER" --role=roles/owner \
            --condition=None --format=none
    fi

    gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT_ID" \
        --member="$FOUNDATION_MEMBER" --role=roles/billing.user --format=none
    gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT_ID" \
        --member="$FOUNDATION_MEMBER" --role=roles/billing.costsManager --format=none
    gcloud billing accounts add-iam-policy-binding "$BILLING_ACCOUNT_ID" \
        --member="$PLAN_MEMBER" --role=roles/billing.viewer --format=none
    pass 'temporary foundation access'
}

change_audit_access() {
    local action="$1"
    local policy_json

    policy_json="$(gcloud projects get-iam-policy "$WORKLOAD_PROJECT_ID" --format=json)"
    if [ "$action" = grant ]; then
        if ! unconditional_binding_exists \
            "$policy_json" roles/iam.securityReviewer "$OPERATOR_PRINCIPAL"; then
            gcloud projects add-iam-policy-binding "$WORKLOAD_PROJECT_ID" \
                --member="$OPERATOR_PRINCIPAL" \
                --role=roles/iam.securityReviewer \
                --condition=None --format=none
        fi
        pass 'temporary audit access'
    else
        if unconditional_binding_exists \
            "$policy_json" roles/iam.securityReviewer "$OPERATOR_PRINCIPAL"; then
            gcloud projects remove-iam-policy-binding "$WORKLOAD_PROJECT_ID" \
                --member="$OPERATOR_PRINCIPAL" \
                --role=roles/iam.securityReviewer \
                --condition=None --format=none
        fi
        pass 'temporary audit access removed'
    fi
}

finish_foundation() {
    local policy_json
    local billing_policy_json
    local parent_policy_json

    policy_json="$(gcloud projects get-iam-policy "$WORKLOAD_PROJECT_ID" --format=json)"
    if unconditional_binding_exists "$policy_json" roles/owner "$FOUNDATION_MEMBER"; then
        gcloud projects remove-iam-policy-binding "$WORKLOAD_PROJECT_ID" \
            --member="$FOUNDATION_MEMBER" --role=roles/owner \
            --condition=None --format=none
    fi

    billing_policy_json="$(gcloud billing accounts get-iam-policy \
        "$BILLING_ACCOUNT_ID" --format=json)"
    if unconditional_binding_exists \
        "$billing_policy_json" roles/billing.user "$FOUNDATION_MEMBER"; then
        # Billing-account IAM does not accept conditional-binding flags.
        gcloud billing accounts remove-iam-policy-binding "$BILLING_ACCOUNT_ID" \
            --member="$FOUNDATION_MEMBER" --role=roles/billing.user --format=none
    fi

    if [ -n "$FOLDER_ID" ]; then
        parent_policy_json="$(gcloud resource-manager folders get-iam-policy \
            "$FOLDER_ID" --format=json)"
        if unconditional_binding_exists \
            "$parent_policy_json" roles/resourcemanager.projectCreator "$FOUNDATION_MEMBER"; then
            gcloud resource-manager folders remove-iam-policy-binding "$FOLDER_ID" \
                --member="$FOUNDATION_MEMBER" \
                --role=roles/resourcemanager.projectCreator \
                --condition=None --format=none
        fi
    elif [ -n "$ORGANIZATION_ID" ]; then
        parent_policy_json="$(gcloud organizations get-iam-policy \
            "$ORGANIZATION_ID" --format=json)"
        if unconditional_binding_exists \
            "$parent_policy_json" roles/resourcemanager.projectCreator "$FOUNDATION_MEMBER"; then
            gcloud organizations remove-iam-policy-binding "$ORGANIZATION_ID" \
                --member="$FOUNDATION_MEMBER" \
                --role=roles/resourcemanager.projectCreator \
                --condition=None --format=none
        fi
    fi

    policy_json="$(gcloud projects get-iam-policy "$WORKLOAD_PROJECT_ID" --format=json)"
    if binding_exists "$policy_json" roles/owner "$FOUNDATION_MEMBER"; then
        fail 'temporary foundation Owner removal'
    fi
    billing_policy_json="$(gcloud billing accounts get-iam-policy \
        "$BILLING_ACCOUNT_ID" --format=json)"
    if binding_exists "$billing_policy_json" roles/billing.user "$FOUNDATION_MEMBER" ||
        ! binding_exists "$billing_policy_json" roles/billing.costsManager "$FOUNDATION_MEMBER" ||
        ! binding_exists "$billing_policy_json" roles/billing.viewer "$PLAN_MEMBER"; then
        fail 'standing billing boundary after cleanup'
    fi
    if [ -n "$FOLDER_ID" ]; then
        parent_policy_json="$(gcloud resource-manager folders get-iam-policy \
            "$FOLDER_ID" --format=json)"
        if binding_exists "$parent_policy_json" roles/resourcemanager.projectCreator "$FOUNDATION_MEMBER"; then
            fail 'temporary folder Project Creator removal'
        fi
    elif [ -n "$ORGANIZATION_ID" ]; then
        parent_policy_json="$(gcloud organizations get-iam-policy \
            "$ORGANIZATION_ID" --format=json)"
        if binding_exists "$parent_policy_json" roles/resourcemanager.projectCreator "$FOUNDATION_MEMBER"; then
            fail 'temporary organization Project Creator removal'
        fi
    fi

    gh variable set GCP_WORKLOAD_PROJECT_ID \
        --repo "$REPOSITORY" --body "$WORKLOAD_PROJECT_ID"
    if [ "$(gh variable get GCP_WORKLOAD_PROJECT_ID --repo "$REPOSITORY")" != \
        "$WORKLOAD_PROJECT_ID" ]; then
        fail 'published workload project coordinate'
    fi
    pass 'temporary foundation access removed'
    pass 'workload project coordinate published'
}

case "$COMMAND" in
    configure)
        configure_foundation
        ;;
    grant)
        grant_foundation_access
        ;;
    grant-audit-access)
        change_audit_access grant
        ;;
    revoke-audit-access)
        change_audit_access revoke
        ;;
    finish)
        finish_foundation
        ;;
esac
