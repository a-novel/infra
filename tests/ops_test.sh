#!/bin/bash

# Exercises operator scripts with local fixtures.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
. "${REPOSITORY_ROOT}/ops/lib/roots.sh"

assert_equal() {
    if [ "$1" != "$2" ]; then
        printf "Expected '%s', got '%s'.\n" "$2" "$1" >&2
        exit 1
    fi
}

assert_absent() {
    if grep -Fq "$2" "$1"; then
        printf "Sensitive fixture text appeared in command output.\n" >&2
        exit 1
    fi
}

assert_equal "$(resolve_root "${REPOSITORY_ROOT}" bootstrap)" "${REPOSITORY_ROOT}/bootstrap"
assert_equal "$(resolve_root "${REPOSITORY_ROOT}" foundation)" "${REPOSITORY_ROOT}/environments/production/foundation"
assert_equal "$(resolve_root "${REPOSITORY_ROOT}" release)" "${REPOSITORY_ROOT}/environments/production/release"

set +e
resolve_root "${REPOSITORY_ROOT}" ../bootstrap >/dev/null 2>&1
INVALID_ROOT_CODE=$?
set -e
assert_equal "${INVALID_ROOT_CODE}" "64"

TEMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf -- "${TEMP_DIR}"
}
trap cleanup INT EXIT

OPERATOR_MOCK_BIN="${TEMP_DIR}/operator-bin"
mkdir -p "${OPERATOR_MOCK_BIN}"
ln -s "${SCRIPT_DIR}/fixtures/fake-operator-gh.sh" "${OPERATOR_MOCK_BIN}/gh"

set +e
env -u INFRA_MANAGEMENT_PROJECT_ID -u INFRA_WORKLOAD_PROJECT_ID \
    "${REPOSITORY_ROOT}/ops/verify-operator-env.sh" \
    >"${TEMP_DIR}/operator-missing.out" 2>"${TEMP_DIR}/operator-missing.err"
MISSING_OPERATOR_ENV_CODE=$?
set -e
assert_equal "${MISSING_OPERATOR_ENV_CODE}" 64
grep -Fq 'INFRA_MANAGEMENT_PROJECT_ID is missing or invalid' \
    "${TEMP_DIR}/operator-missing.err"

set +e
INFRA_MANAGEMENT_PROJECT_ID=INVALID \
    INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
    "${REPOSITORY_ROOT}/ops/verify-operator-env.sh" \
    >"${TEMP_DIR}/operator-malformed.out" 2>"${TEMP_DIR}/operator-malformed.err"
MALFORMED_OPERATOR_ENV_CODE=$?
set -e
assert_equal "${MALFORMED_OPERATOR_ENV_CODE}" 64
grep -Fq 'INFRA_MANAGEMENT_PROJECT_ID is missing or invalid' \
    "${TEMP_DIR}/operator-malformed.err"

set +e
INFRA_MANAGEMENT_PROJECT_ID=replace-with-management-project-id \
    INFRA_WORKLOAD_PROJECT_ID=replace-with-workload-project-id \
    "${REPOSITORY_ROOT}/ops/verify-operator-env.sh" \
    >"${TEMP_DIR}/operator-placeholder.out" 2>"${TEMP_DIR}/operator-placeholder.err"
PLACEHOLDER_OPERATOR_ENV_CODE=$?
set -e
assert_equal "${PLACEHOLDER_OPERATOR_ENV_CODE}" 64
grep -Fq 'INFRA_MANAGEMENT_PROJECT_ID is missing or invalid' \
    "${TEMP_DIR}/operator-placeholder.err"

OPERATOR_OUTPUT="$(
    INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
        INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
        "${REPOSITORY_ROOT}/ops/verify-operator-env.sh"
)"
assert_equal "${OPERATOR_OUTPUT}" 'PASS operator project coordinates'

set +e
INFRA_MANAGEMENT_PROJECT_ID=workload-project-prod \
    INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
    "${REPOSITORY_ROOT}/ops/verify-operator-env.sh" \
    >"${TEMP_DIR}/operator-equal.out" 2>"${TEMP_DIR}/operator-equal.err"
EQUAL_OPERATOR_ENV_CODE=$?
set -e
assert_equal "${EQUAL_OPERATOR_ENV_CODE}" 64
grep -Fq 'management and workload project IDs must differ' \
    "${TEMP_DIR}/operator-equal.err"

PUBLISHED_OPERATOR_OUTPUT="$(
    PATH="${OPERATOR_MOCK_BIN}:${PATH}" \
        INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
        INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
        "${REPOSITORY_ROOT}/ops/verify-operator-env.sh" --github
)"
assert_equal "${PUBLISHED_OPERATOR_OUTPUT}" 'PASS published project coordinates'

UNPUBLISHED_OPERATOR_OUTPUT="$(
    PATH="${OPERATOR_MOCK_BIN}:${PATH}" \
        FAKE_OPERATOR_GITHUB_MODE=unpublished \
        INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
        INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
        "${REPOSITORY_ROOT}/ops/verify-operator-env.sh" --github
)"
assert_equal "${UNPUBLISHED_OPERATOR_OUTPUT}" 'PASS published project coordinates'

set +e
PATH="${OPERATOR_MOCK_BIN}:${PATH}" \
    FAKE_OPERATOR_GITHUB_MODE=mismatch \
    INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
    INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
    "${REPOSITORY_ROOT}/ops/verify-operator-env.sh" --github \
    >"${TEMP_DIR}/operator-mismatch.out" 2>"${TEMP_DIR}/operator-mismatch.err"
MISMATCHED_OPERATOR_ENV_CODE=$?
set -e
assert_equal "${MISMATCHED_OPERATOR_ENV_CODE}" 65
grep -Fq 'does not match the published GitHub coordinate' \
    "${TEMP_DIR}/operator-mismatch.err"

SECRET_MOCK_BIN="${TEMP_DIR}/secret-bin"
mkdir -p "${SECRET_MOCK_BIN}"
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    '[ "$*" = "variable get GCP_MANAGEMENT_PROJECT_ID --repo a-novel/infra" ]' \
    'printf "%s" "agora-management-test"' \
    >"${SECRET_MOCK_BIN}/gh"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'case "$*" in' \
    '  "secrets describe production-authentication-postgres-password --project=agora-management-test --format=yaml(name,annotations,createTime,versionDestroyTtl)")' \
    '    printf "%s\n" "name: production-authentication-postgres-password" ;;' \
    '  "secrets versions add production-authentication-postgres-password --project=agora-management-test --data-file=- --quiet --format=value(name.basename())")' \
    '    payload="$(cat)"' \
    '    [ "$payload" = "$FAKE_EXPECTED_SECRET" ]' \
    '    printf "%s" "7" ;;' \
    '  "secrets versions describe 7 --secret=production-authentication-postgres-password --project=agora-management-test --format=value(state)")' \
    '    printf "%s" "ENABLED" ;;' \
    '  "secrets versions describe 7 --secret=production-authentication-postgres-password --project=agora-management-test --format=yaml(name,state,createTime,destroyTime,scheduledDestroyTime)")' \
    '    printf "%s\n" "state: ENABLED" ;;' \
    '  *) exit 64 ;;' \
    'esac' \
    >"${SECRET_MOCK_BIN}/gcloud"
chmod 0700 "${SECRET_MOCK_BIN}/gh" "${SECRET_MOCK_BIN}/gcloud"

POSTGRES_SECRET='Abcdefghijklmnopqrstuvwxyz_12345'
CREATED_SECRET_VERSION="$(
    printf '%s\n%s\n' "${POSTGRES_SECRET}" "${POSTGRES_SECRET}" \
        | PATH="${SECRET_MOCK_BIN}:${PATH}" \
            FAKE_EXPECTED_SECRET="${POSTGRES_SECRET}" \
            INFRA_MANAGEMENT_PROJECT_ID=agora-management-test \
            INFRA_WORKLOAD_PROJECT_ID=agora-production-test \
            "${REPOSITORY_ROOT}/ops/add-secret-version.sh" \
                production-authentication-postgres-password \
                2>"${TEMP_DIR}/add-secret.err"
)"
assert_equal "${CREATED_SECRET_VERSION}" \
    'Created production-authentication-postgres-password version 7.'
assert_absent "${TEMP_DIR}/add-secret.err" "${POSTGRES_SECRET}"

set +e
"${REPOSITORY_ROOT}/ops/add-secret-version.sh" \
    production-authentication-postgres-password \
    production-authentication-postgres-password \
    >"${TEMP_DIR}/duplicate-secret.out" 2>"${TEMP_DIR}/duplicate-secret.err"
DUPLICATE_SECRET_CODE=$?
set -e
assert_equal "${DUPLICATE_SECRET_CODE}" 65
grep -Fq 'Refusing duplicate secret ID' "${TEMP_DIR}/duplicate-secret.err"

# The scheduled synthetic check must resolve only the reviewed project/region,
# keep response content private, and reject every partial-health state.
HEALTH_MOCK_BIN="${TEMP_DIR}/health-bin"
mkdir -p "${HEALTH_MOCK_BIN}"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'expected="run services describe agora-authentication-rest --project=agora-production-test --region=europe-west1 --format=value(status.url) --quiet"' \
    '[ "$*" = "${expected}" ]' \
    'printf "%s\n" "${FAKE_AUTH_SERVICE_URL:-https://agora-authentication-rest-123456789012.europe-west1.run.app}"' \
    >"${HEALTH_MOCK_BIN}/gcloud"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'arguments="$*"' \
    'output=""' \
    'while [ "$#" -gt 0 ]; do' \
    '    if [ "$1" = --output ]; then' \
    '        output="$2"' \
    '        shift 2' \
    '    else' \
    '        shift' \
    '    fi' \
    'done' \
    '[ -n "${output}" ]' \
    '[[ "${arguments}" == *"--proto =https"* ]]' \
    '[[ "${arguments}" == *"/v2/healthcheck" ]]' \
    'printf "%s" "${FAKE_AUTH_HEALTH_BODY}" >"${output}"' \
    'printf "%s" "${FAKE_AUTH_HEALTH_STATUS:-200}"' \
    >"${HEALTH_MOCK_BIN}/curl"
chmod 0700 "${HEALTH_MOCK_BIN}/gcloud" "${HEALTH_MOCK_BIN}/curl"
printf '%s\n' \
    '{"workload_project_id":"agora-production-test","region":"europe-west1"}' \
    >"${TEMP_DIR}/foundation-health.json"

HEALTHY_BODY='{"client:smtp":{"status":"up"},"api:jsonKeys":{"status":"up"},"client:postgres":{"status":"up"}}'
PATH="${HEALTH_MOCK_BIN}:${PATH}" \
    FAKE_AUTH_HEALTH_BODY="${HEALTHY_BODY}" \
    "${REPOSITORY_ROOT}/ops/check-authentication-health.sh" \
    "${TEMP_DIR}/foundation-health.json" >"${TEMP_DIR}/health.out" 2>"${TEMP_DIR}/health.err"
grep -Fq 'Authentication and all declared dependencies are healthy.' "${TEMP_DIR}/health.out"
assert_absent "${TEMP_DIR}/health.out" 'agora-production-test'
assert_absent "${TEMP_DIR}/health.out" 'client:smtp'

assert_health_rejected() {
    local body="$1"
    local status="${2:-200}"
    local code=0

    set +e
    PATH="${HEALTH_MOCK_BIN}:${PATH}" \
        FAKE_AUTH_HEALTH_BODY="${body}" \
        FAKE_AUTH_HEALTH_STATUS="${status}" \
        "${REPOSITORY_ROOT}/ops/check-authentication-health.sh" \
        "${TEMP_DIR}/foundation-health.json" \
        >"${TEMP_DIR}/unhealthy.out" 2>"${TEMP_DIR}/unhealthy.err"
    code=$?
    set -e
    assert_equal "${code}" 70
    assert_absent "${TEMP_DIR}/unhealthy.out" 'fixture-private-response'
    assert_absent "${TEMP_DIR}/unhealthy.err" 'fixture-private-response'
}

assert_health_rejected \
    '{"api:jsonKeys":{"status":"down"},"client:postgres":{"status":"up"},"client:smtp":{"status":"up"},"detail":"fixture-private-response"}'
assert_health_rejected \
    '{"api:jsonKeys":{"status":"up"},"client:postgres":{"status":"down"},"client:smtp":{"status":"up"}}'
assert_health_rejected \
    '{"api:jsonKeys":{"status":"up"},"client:postgres":{"status":"up"},"client:smtp":{"status":"down"}}'
assert_health_rejected "${HEALTHY_BODY}" 503

set +e
PATH="${HEALTH_MOCK_BIN}:${PATH}" \
    FAKE_AUTH_HEALTH_BODY="${HEALTHY_BODY}" \
    FAKE_AUTH_SERVICE_URL='http://authentication.example.test' \
    "${REPOSITORY_ROOT}/ops/check-authentication-health.sh" \
    "${TEMP_DIR}/foundation-health.json" >/dev/null 2>&1
INVALID_HEALTH_URL_CODE=$?
set -e
assert_equal "${INVALID_HEALTH_URL_CODE}" 70

"${REPOSITORY_ROOT}/ops/plan-summary.sh" foundation "${SCRIPT_DIR}/fixtures/plans/safe.json" >"${TEMP_DIR}/safe.out" 2>"${TEMP_DIR}/safe.err"
grep -Fq $'create\tgoogle_cloud_run_v2_job\t1' "${TEMP_DIR}/safe.out"
grep -Fq $'import\tgoogle_project\t1' "${TEMP_DIR}/safe.out"
grep -Fq $'update\tgoogle_cloud_run_v2_service\t1' "${TEMP_DIR}/safe.out"
if grep -Fq $'no-op\t' "${TEMP_DIR}/safe.out"; then
    printf "No-op resources must not appear in the sanitized summary.\n" >&2
    exit 1
fi
assert_absent "${TEMP_DIR}/safe.out" "fixture-secret-must-not-be-printed"
assert_absent "${TEMP_DIR}/safe.out" "fixture-password"
assert_absent "${TEMP_DIR}/safe.out" "fixture-token-must-not-be-printed"
assert_absent "${TEMP_DIR}/safe.out" "fixture-import-id-must-not-be-printed"

set +e
"${REPOSITORY_ROOT}/ops/plan-summary.sh" foundation "${SCRIPT_DIR}/fixtures/plans/protected.json" >"${TEMP_DIR}/protected.out" 2>"${TEMP_DIR}/protected.err"
PROTECTED_CODE=$?
set -e
assert_equal "${PROTECTED_CODE}" "3"
grep -Fq $'delete\tgoogle_project\t1' "${TEMP_DIR}/protected.out"
grep -Fq $'forget\tgoogle_secret_manager_secret\t1' "${TEMP_DIR}/protected.out"
grep -Fq $'replace\tgoogle_compute_disk\t1' "${TEMP_DIR}/protected.out"
grep -Fq $'delete\tgoogle_compute_firewall\t1' "${TEMP_DIR}/protected.out"
grep -Fq $'delete\tgoogle_cloud_run_v2_service\t1' "${TEMP_DIR}/protected.out"
grep -Fq "google_cloud_run_v2_service (1)" "${TEMP_DIR}/protected.err"
grep -Fq "google_compute_disk (1)" "${TEMP_DIR}/protected.err"
grep -Fq "google_compute_firewall (1)" "${TEMP_DIR}/protected.err"
grep -Fq "google_project (1)" "${TEMP_DIR}/protected.err"
grep -Fq "google_secret_manager_secret (1)" "${TEMP_DIR}/protected.err"
grep -Fq "google_service_account (1)" "${TEMP_DIR}/protected.err"
grep -Fq "google_storage_managed_folder (1)" "${TEMP_DIR}/protected.err"
assert_absent "${TEMP_DIR}/protected.out" "fixture-disk-name"
assert_absent "${TEMP_DIR}/protected.err" "fixture-project-id"
assert_absent "${TEMP_DIR}/protected.err" "fixture-forgotten-secret"
assert_absent "${TEMP_DIR}/protected.err" "fixture-future-service"

set +e
"${REPOSITORY_ROOT}/ops/plan-summary.sh" foundation "${SCRIPT_DIR}/fixtures/plans/unsupported.json" >"${TEMP_DIR}/unsupported.out" 2>"${TEMP_DIR}/unsupported.err"
UNSUPPORTED_CODE=$?
set -e
assert_equal "${UNSUPPORTED_CODE}" "65"
grep -Fq "unsupported action combination" "${TEMP_DIR}/unsupported.err"
assert_absent "${TEMP_DIR}/unsupported.out" "fixture-unsupported-action-value"
assert_absent "${TEMP_DIR}/unsupported.err" "fixture-unsupported-action-value"

# The wrapper must preserve OpenTofu's detailed code for reviewed plans while
# mapping every kind of detected drift (including deletion) to the same alert.
TOFU_GATE_BIN="${TEMP_DIR}/tofu-gate-bin"
mkdir -p "${TOFU_GATE_BIN}"
ln -s "${SCRIPT_DIR}/fixtures/fake-tofu.sh" "${TOFU_GATE_BIN}/tofu"
printf '%s\n' '#!/bin/bash' 'exit 0' >"${TOFU_GATE_BIN}/git"
chmod 0700 "${TOFU_GATE_BIN}/git"

assert_tofu_gate_code() {
    local action="$1"
    local fixture="$2"
    local expected="$3"
    local fixture_name=""
    local plan_file=""
    local code=0
    local arguments=("${action}" foundation agora-state-test)
    fixture_name="$(basename "${fixture}")"
    plan_file="${TEMP_DIR}/${action}-${fixture_name}.tfplan"
    if [ "${action}" = plan ]; then
        arguments+=("${plan_file}")
    fi
    set +e
    PATH="${TOFU_GATE_BIN}:${PATH}" \
        FAKE_TOFU_PLAN_CODE=2 \
        FAKE_TOFU_PLAN_JSON="${fixture}" \
        "${REPOSITORY_ROOT}/ops/tofu-gate.sh" "${arguments[@]}" \
        >"${TEMP_DIR}/tofu-gate.out" 2>"${TEMP_DIR}/tofu-gate.err"
    code=$?
    set -e
    assert_equal "${code}" "${expected}"
}

assert_tofu_gate_code plan "${SCRIPT_DIR}/fixtures/plans/safe.json" 2
assert_tofu_gate_code plan "${SCRIPT_DIR}/fixtures/plans/protected.json" 3
assert_tofu_gate_code drift "${SCRIPT_DIR}/fixtures/plans/safe.json" 2
assert_tofu_gate_code drift "${SCRIPT_DIR}/fixtures/plans/protected.json" 2

set +e
PATH="${TOFU_GATE_BIN}:${PATH}" \
    FAKE_TOFU_FAIL_ACTION=plan \
    FAKE_TOFU_DIAGNOSTICS="${SCRIPT_DIR}/fixtures/plan-diagnostics.jsonl" \
    "${REPOSITORY_ROOT}/ops/tofu-gate.sh" plan foundation agora-state-test \
    "${TEMP_DIR}/failed-plan.tfplan" \
    >"${TEMP_DIR}/failed-plan.out" 2>"${TEMP_DIR}/failed-plan.err"
FAILED_PLAN_CODE=$?
set -e
assert_equal "${FAILED_PLAN_CODE}" 1
grep -Fq 'OpenTofu planning failed' "${TEMP_DIR}/failed-plan.err"
grep -Fq $'PERMISSION_DENIED\tgoogle_project\tidentity.tf:47\t1' \
    "${TEMP_DIR}/failed-plan.err"
grep -Fq $'UNKNOWN\tgoogle_compute_disk\tcapacity.tf:82\t1' \
    "${TEMP_DIR}/failed-plan.err"
grep -Fq $'CONFIGURATION\t-\tchecks.tf:7\t1' "${TEMP_DIR}/failed-plan.err"
grep -Fq $'CONFIGURATION\t-\tcost.tf:27\t1' "${TEMP_DIR}/failed-plan.err"
grep -Fq $'ZONE_RESOURCE_POOL_EXHAUSTED\tgoogle_compute_disk\tdatabase.tf:54\t1' \
    "${TEMP_DIR}/failed-plan.err"
assert_absent "${TEMP_DIR}/failed-plan.out" 'fixture-sensitive'
assert_absent "${TEMP_DIR}/failed-plan.err" 'fixture-sensitive'

FAILED_APPLY_PLAN="${TEMP_DIR}/failed-apply.tfplan"
: >"${FAILED_APPLY_PLAN}"
set +e
PATH="${TOFU_GATE_BIN}:${PATH}" \
    FAKE_TOFU_FAIL_ACTION=apply \
    FAKE_TOFU_DIAGNOSTICS="${SCRIPT_DIR}/fixtures/plan-diagnostics.jsonl" \
    "${REPOSITORY_ROOT}/ops/tofu-gate.sh" apply foundation agora-state-test \
    "${FAILED_APPLY_PLAN}" >"${TEMP_DIR}/failed-apply.out" 2>"${TEMP_DIR}/failed-apply.err"
FAILED_APPLY_CODE=$?
set -e
assert_equal "${FAILED_APPLY_CODE}" 1
grep -Fq 'Protected OpenTofu apply failed' "${TEMP_DIR}/failed-apply.err"
grep -Fq $'ZONE_RESOURCE_POOL_EXHAUSTED\tgoogle_compute_disk\tdatabase.tf:54\t1' \
    "${TEMP_DIR}/failed-apply.err"
assert_absent "${TEMP_DIR}/failed-apply.out" 'fixture-sensitive'
assert_absent "${TEMP_DIR}/failed-apply.err" 'fixture-sensitive-diagnostic'
assert_absent "${TEMP_DIR}/failed-apply.err" 'fixture-sensitive-detail'

if grep -RqE 'resource[[:space:]]+"(google_secret_manager_secret_version|google_service_account_key)"' \
    "${REPOSITORY_ROOT}/bootstrap" \
    "${REPOSITORY_ROOT}/environments/production/foundation" \
    --include='*.tf'; then
    printf "Infrastructure must not place secret payloads or service-account keys in state.\n" >&2
    exit 1
fi

if grep -RqE 'resource[[:space:]]+"google_secret_manager_secret_iam_member"[[:space:]]+"recovery"' \
    "${REPOSITORY_ROOT}/bootstrap" --include='*.tf'; then
    printf "GitHub recovery automation must not receive Secret Manager payload access.\n" >&2
    exit 1
fi

if grep -RqE 'roles/(owner|editor)' \
    "${REPOSITORY_ROOT}/bootstrap" \
    "${REPOSITORY_ROOT}/environments/production/foundation" \
    --include='*.tf'; then
    printf "Infrastructure automation must not use primitive Owner or Editor roles.\n" >&2
    exit 1
fi

if grep -RqE 'resource[[:space:]]+"google_(compute_router|compute_router_nat|vpc_access_connector)"' \
    "${REPOSITORY_ROOT}/environments/production/foundation" \
    --include='*.tf'; then
    printf "The launch foundation must not add an idle NAT, router, or VPC connector.\n" >&2
    exit 1
fi

if grep -Fq 'allowed_audiences' "${REPOSITORY_ROOT}/bootstrap/identity.tf"; then
    printf "GitHub federation must use Google's canonical default audience.\n" >&2
    exit 1
fi

# Destructive approval is historical merge-gate evidence, not the PR's mutable
# current label list. A post-merge label, a pre-merge removal, or a non-maintainer
# actor must never authorize an apply.
DELETION_MOCK_BIN="${TEMP_DIR}/deletion-bin"
mkdir -p "${DELETION_MOCK_BIN}"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'if [[ "$*" == *"/commits/"*"/pulls"* ]]; then' \
    '    printf "%s\n" "${PR_FIXTURE}"' \
    'elif [[ "$*" == *"/timeline"* ]]; then' \
    '    printf "%s\n" "${TIMELINE_FIXTURE}"' \
    'elif [[ "$*" == *"/collaborators/"*"/permission"* ]]; then' \
    '    printf "%s\n" "${APPROVER_PERMISSION}"' \
    'else' \
    '    exit 1' \
    'fi' \
    >"${DELETION_MOCK_BIN}/gh"
chmod 0700 "${DELETION_MOCK_BIN}/gh"

DELETION_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PR_FIXTURE="[{\"number\":42,\"merged_at\":\"2026-08-25T12:00:00Z\",\"merge_commit_sha\":\"${DELETION_COMMIT}\",\"labels\":[]}]"
PRE_MERGE_TIMELINE='[[{"id":1,"event":"labeled","created_at":"2026-08-25T11:00:00Z","label":{"name":"allow-resource-deletion"},"actor":{"login":"maintainer"}},{"id":2,"event":"merged","created_at":"2026-08-25T12:00:00Z"}]]'
PATH="${DELETION_MOCK_BIN}:${PATH}" \
    PR_FIXTURE="${PR_FIXTURE}" \
    TIMELINE_FIXTURE="${PRE_MERGE_TIMELINE}" \
    APPROVER_PERMISSION=write \
    "${REPOSITORY_ROOT}/ops/verify-deletion-label.sh" \
    a-novel/infra "${DELETION_COMMIT}" >"${TEMP_DIR}/deletion-approved.out"
grep -Fq 'Resource-deletion approval verified on PR #42.' "${TEMP_DIR}/deletion-approved.out"

assert_deletion_gate_rejects() {
    local timeline="$1"
    local permission="$2"
    local code=0
    set +e
    PATH="${DELETION_MOCK_BIN}:${PATH}" \
        PR_FIXTURE="${PR_FIXTURE}" \
        TIMELINE_FIXTURE="${timeline}" \
        APPROVER_PERMISSION="${permission}" \
        "${REPOSITORY_ROOT}/ops/verify-deletion-label.sh" \
        a-novel/infra "${DELETION_COMMIT}" >/dev/null 2>&1
    code=$?
    set -e
    assert_equal "${code}" 77
}

assert_deletion_gate_rejects \
    '[[{"id":1,"event":"merged","created_at":"2026-08-25T12:00:00Z"},{"id":2,"event":"labeled","created_at":"2026-08-25T12:01:00Z","label":{"name":"allow-resource-deletion"},"actor":{"login":"maintainer"}}]]' \
    write
assert_deletion_gate_rejects \
    '[[{"id":1,"event":"labeled","created_at":"2026-08-25T11:00:00Z","label":{"name":"allow-resource-deletion"},"actor":{"login":"maintainer"}},{"id":2,"event":"unlabeled","created_at":"2026-08-25T11:30:00Z","label":{"name":"allow-resource-deletion"},"actor":{"login":"maintainer"}},{"id":3,"event":"merged","created_at":"2026-08-25T12:00:00Z"}]]' \
    write
assert_deletion_gate_rejects "${PRE_MERGE_TIMELINE}" triage

# Project cleanup is permitted only for the exact committed recovery target.
# The mock records deletion without exposing project metadata in script output.
if ! jq --exit-status '
  .schemaVersion == 1 and
  (if .replacementProject == null then
    .sourceReceipt == null and .crossProjectAccessRevoked == false
   else
    (.replacementProject | test("^[a-z][a-z0-9-]{4,28}[a-z0-9]$")) and
    (.sourceReceipt | test("^[1-9][0-9]*-[1-9][0-9]*$")) and
    .crossProjectAccessRevoked == true
   end)
' "${REPOSITORY_ROOT}/deploy/production/recovery-cleanup.json" >/dev/null; then
    printf 'The recovery cleanup authorization has an invalid shape.\n' >&2
    exit 1
fi

# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'if [ "$1 $2" = "projects describe" ] && [[ "$*" == *"--format=json"* ]]; then' \
    '    if [ "${RECOVERY_LABEL_VALID:-true}" = true ]; then' \
    '        printf '\''{"projectId":"agora-recovery-test","lifecycleState":"ACTIVE","labels":{"application":"agora","environment":"production","managed-by":"opentofu","plane":"workload","recovery":"true"}}\n'\''' \
    '    else' \
    '        printf '\''{"projectId":"agora-recovery-test","lifecycleState":"ACTIVE","labels":{"recovery":"false"}}\n'\''' \
    '    fi' \
    'elif [ "$1 $2" = "projects describe" ]; then' \
    '    if [ -f "${RECOVERY_DELETE_STATE}" ]; then printf "DELETE_REQUESTED\n"; else printf "ACTIVE\n"; fi' \
    'elif [ "$1 $2" = "projects get-iam-policy" ]; then' \
    '    printf "roles/resourcemanager.projectDeleter\n"' \
    'elif [ "$1 $2" = "projects delete" ]; then' \
    '    : >"${RECOVERY_DELETE_STATE}"' \
    'else' \
    '    exit 1' \
    'fi' \
    >"${DELETION_MOCK_BIN}/gcloud"
chmod 0700 "${DELETION_MOCK_BIN}/gcloud"

jq -n '{management_project_id:"agora-management-test",workload_project_id:"agora-production-test"}' \
    >"${TEMP_DIR}/cleanup-foundation.json"
jq -n '{schemaVersion:1,replacementProject:"agora-recovery-test",sourceReceipt:"500-1",crossProjectAccessRevoked:true}' \
    >"${TEMP_DIR}/cleanup-authorized.json"
RECOVERY_DELETE_STATE="${TEMP_DIR}/recovery-delete-requested"
PATH="${DELETION_MOCK_BIN}:${PATH}" \
    PR_FIXTURE="${PR_FIXTURE}" TIMELINE_FIXTURE="${PRE_MERGE_TIMELINE}" \
    APPROVER_PERMISSION=write RECOVERY_DELETE_STATE="${RECOVERY_DELETE_STATE}" \
    "${REPOSITORY_ROOT}/ops/delete-recovery-project.sh" \
    a-novel/infra "${DELETION_COMMIT}" agora-recovery-test 500-1 \
    "${TEMP_DIR}/cleanup-foundation.json" "${TEMP_DIR}/cleanup-authorized.json" \
    'DELETE agora-recovery-test' >"${TEMP_DIR}/recovery-cleanup.out"
grep -Fq 'Disposable recovery project is DELETE_REQUESTED.' \
    "${TEMP_DIR}/recovery-cleanup.out"
test -f "${RECOVERY_DELETE_STATE}"

assert_recovery_cleanup_rejects() {
    local authorization="$1"
    local confirmation="$2"
    local label_valid="$3"
    local expected="$4"
    local foundation="${5:-${TEMP_DIR}/cleanup-foundation.json}"
    local code=0
    rm -f -- "${RECOVERY_DELETE_STATE}"
    set +e
    PATH="${DELETION_MOCK_BIN}:${PATH}" \
        PR_FIXTURE="${PR_FIXTURE}" TIMELINE_FIXTURE="${PRE_MERGE_TIMELINE}" \
        APPROVER_PERMISSION=write RECOVERY_DELETE_STATE="${RECOVERY_DELETE_STATE}" \
        RECOVERY_LABEL_VALID="${label_valid}" \
        "${REPOSITORY_ROOT}/ops/delete-recovery-project.sh" \
        a-novel/infra "${DELETION_COMMIT}" agora-recovery-test 500-1 \
        "${foundation}" "${authorization}" \
        "${confirmation}" >/dev/null 2>&1
    code=$?
    set -e
    assert_equal "${code}" "${expected}"
    test ! -e "${RECOVERY_DELETE_STATE}"
}

jq '.crossProjectAccessRevoked = false' "${TEMP_DIR}/cleanup-authorized.json" \
    >"${TEMP_DIR}/cleanup-not-revoked.json"
jq '.management_project_id = "invalid project"' "${TEMP_DIR}/cleanup-foundation.json" \
    >"${TEMP_DIR}/cleanup-invalid-foundation.json"
assert_recovery_cleanup_rejects \
    "${TEMP_DIR}/cleanup-authorized.json" 'DELETE wrong-project' true 65
assert_recovery_cleanup_rejects \
    "${TEMP_DIR}/cleanup-not-revoked.json" 'DELETE agora-recovery-test' true 77
assert_recovery_cleanup_rejects \
    "${TEMP_DIR}/cleanup-authorized.json" 'DELETE agora-recovery-test' false 77
assert_recovery_cleanup_rejects \
    "${TEMP_DIR}/cleanup-authorized.json" 'DELETE agora-recovery-test' true 77 \
    "${TEMP_DIR}/cleanup-invalid-foundation.json"

# Cloud Quotas omits the default-false reconciling field on some settled
# responses. Omission is accepted, while a pending preference still fails.
PREFLIGHT_MOCK_BIN="${TEMP_DIR}/preflight-bin"
mkdir -p "${PREFLIGHT_MOCK_BIN}"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'if [ -n "${PREFLIGHT_GCLOUD_LOG:-}" ]; then printf "%s\n" "$1 $2 $3" >>"${PREFLIGHT_GCLOUD_LOG}"; fi' \
    'if [ "$1 $2 $3" = "secrets versions describe" ]; then' \
    '    if [ "${PREFLIGHT_SECRET_MISSING:-false}" = true ]; then exit 1; fi' \
    '    printf "ENABLED\n"' \
    'elif [ "$1 $2 $3" = "quotas preferences list" ]; then' \
    '    jq --argjson pending "${PREFLIGHT_PENDING:-false}" '\''
    [
      {service:"run.googleapis.com", dimensions:{region:"europe-west1"}, justification:"Agora production cost ceiling; changes require reviewed infrastructure code.", quotaConfig:{preferredValue:"8000", grantedValue:"8000"}},
      {service:"run.googleapis.com", dimensions:{region:"europe-west1"}, justification:"Agora production cost ceiling; changes require reviewed infrastructure code.", quotaConfig:{preferredValue:"17179869184", grantedValue:"17179869184"}},
      {service:"compute.googleapis.com", dimensions:{region:"europe-west1"}, justification:"Agora production cost ceiling; changes require reviewed infrastructure code.", reconciling:$pending, quotaConfig:{preferredValue:"4", grantedValue:"4"}}
    ]'\'' <<EOF
null
EOF' \
    'else' \
    '    exit 1' \
    'fi' \
    >"${PREFLIGHT_MOCK_BIN}/gcloud"
chmod 0700 "${PREFLIGHT_MOCK_BIN}/gcloud"

jq -n '
  {
    schemaVersion: 1,
    action: "rollback",
    cloud: {
      managementProjectId: "agora-management-test",
      workloadProjectId: "agora-production-test",
      region: "europe-west1",
      secretVersions: [],
      quotaExpectations: {
        cloud_run_cpu_millicpu: 8000,
        cloud_run_memory_bytes: 17179869184,
        compute_cpu: 4
      }
    }
  }
' >"${TEMP_DIR}/preflight.json"
PATH="${PREFLIGHT_MOCK_BIN}:${PATH}" \
    "${REPOSITORY_ROOT}/ops/preflight-release.sh" \
    "${TEMP_DIR}/preflight.json" >"${TEMP_DIR}/preflight.out"

# A deploy always has consumers, while the compensated pre-first-release
# rollback is the sole valid empty inventory.
jq '.action = "deploy"' "${TEMP_DIR}/preflight.json" \
    >"${TEMP_DIR}/preflight-empty-deploy.json"
PREFLIGHT_GCLOUD_LOG="${TEMP_DIR}/preflight-gcloud.log"
: >"${PREFLIGHT_GCLOUD_LOG}"
set +e
PATH="${PREFLIGHT_MOCK_BIN}:${PATH}" \
    PREFLIGHT_GCLOUD_LOG="${PREFLIGHT_GCLOUD_LOG}" \
    "${REPOSITORY_ROOT}/ops/preflight-release.sh" \
    "${TEMP_DIR}/preflight-empty-deploy.json" >/dev/null 2>&1
EMPTY_DEPLOY_PREFLIGHT_CODE=$?
set -e
assert_equal "${EMPTY_DEPLOY_PREFLIGHT_CODE}" 65
assert_equal "$(wc -c <"${PREFLIGHT_GCLOUD_LOG}")" 0

jq '
  .action = "deploy" |
  .cloud.secretVersions = [range(1; 10) | ["production-test-\(.)", .]]
' "${TEMP_DIR}/preflight.json" >"${TEMP_DIR}/preflight-deploy.json"

: >"${PREFLIGHT_GCLOUD_LOG}"
PATH="${PREFLIGHT_MOCK_BIN}:${PATH}" \
    PREFLIGHT_GCLOUD_LOG="${PREFLIGHT_GCLOUD_LOG}" \
    "${REPOSITORY_ROOT}/ops/preflight-release.sh" \
    "${TEMP_DIR}/preflight-deploy.json" >/dev/null
assert_equal "$(grep -Fxc 'secrets versions describe' "${PREFLIGHT_GCLOUD_LOG}")" 9
assert_equal "$(grep -Fxc 'quotas preferences list' "${PREFLIGHT_GCLOUD_LOG}")" 1

# A missing or inaccessible version stops the release before quota inspection
# and before the orchestrator can reach image promotion or workload mutation.
: >"${PREFLIGHT_GCLOUD_LOG}"
set +e
PATH="${PREFLIGHT_MOCK_BIN}:${PATH}" \
    PREFLIGHT_GCLOUD_LOG="${PREFLIGHT_GCLOUD_LOG}" \
    PREFLIGHT_SECRET_MISSING=true \
    "${REPOSITORY_ROOT}/ops/preflight-release.sh" \
    "${TEMP_DIR}/preflight-deploy.json" >/dev/null 2>&1
MISSING_SECRET_PREFLIGHT_CODE=$?
set -e
assert_equal "${MISSING_SECRET_PREFLIGHT_CODE}" 70
assert_equal "$(grep -Fxc 'secrets versions describe' "${PREFLIGHT_GCLOUD_LOG}")" 1
if grep -Fqx 'quotas preferences list' "${PREFLIGHT_GCLOUD_LOG}"; then
    printf 'A missing secret version must stop preflight before quota inspection.\n' >&2
    exit 1
fi

set +e
PATH="${PREFLIGHT_MOCK_BIN}:${PATH}" PREFLIGHT_PENDING=true \
    "${REPOSITORY_ROOT}/ops/preflight-release.sh" \
    "${TEMP_DIR}/preflight.json" >/dev/null 2>&1
PENDING_PREFLIGHT_CODE=$?
set -e
assert_equal "${PENDING_PREFLIGHT_CODE}" 70

# The database release helper is intentionally narrower than a general MIG
# command wrapper: tests capture every argument and reject invalid input before
# a cloud command can run.
MOCK_BIN="${TEMP_DIR}/bin"
GCLOUD_ARGUMENT_LOG="${TEMP_DIR}/gcloud-arguments.log"
mkdir -p "${MOCK_BIN}"
# These references expand when the generated mock runs, not while this test
# writes it.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'printf "CALL\\n" >> "${GCLOUD_ARGUMENT_LOG}"' \
    'printf "%s\\n" "$@" >> "${GCLOUD_ARGUMENT_LOG}"' \
    'if [[ "$*" == *"instance-groups managed describe"* ]]; then' \
    '    if [[ "${INVALID_METADATA_SHAPE:-false}" == "true" ]]; then' \
    "        printf '%s\\n' '{\"allInstancesConfig\":{\"properties\":{\"metadata\":{\"unexpected-key\":\"value\"}}}}'" \
    '    else' \
    '        if [[ "${INITIAL_DATABASE_RELEASE:-false}" == "true" ]]; then current_revision=""; else current_revision="ffffffffffffffffffffffffffffffffffffffff"; fi' \
    '        printf "{\"allInstancesConfig\":{\"properties\":{\"metadata\":{\"agora-authentication-database-image\":\"\",\"agora-authentication-postgres-backup-password-version\":\"0\",\"agora-authentication-postgres-password-version\":\"0\",\"agora-database-release-revision\":\"%s\",\"agora-json-keys-database-image\":\"\",\"agora-json-keys-postgres-backup-password-version\":\"0\",\"agora-json-keys-postgres-password-version\":\"0\"}}}}\n" "${current_revision}"' \
    '    fi' \
    'fi' \
    'if [[ "$*" == *"compute snapshots list"* ]]; then' \
    '    if [[ "${STALE_SNAPSHOT:-false}" == "true" ]]; then snapshot_time="$(date -u --date="7 hours ago" +%Y-%m-%dT%H:%M:%SZ)"; else snapshot_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi' \
    '    if [[ "${MANUAL_SNAPSHOT:-false}" == "true" ]]; then snapshot_auto_created=false; else snapshot_auto_created=true; fi' \
    '    printf "[{\"name\":\"agora-scheduled-snapshot\",\"autoCreated\":%s,\"sourceDisk\":\"https://www.googleapis.com/compute/v1/projects/agora-production-test/zones/europe-west1-c/disks/agora-data\",\"status\":\"READY\",\"creationTimestamp\":\"%s\",\"storageLocations\":[\"europe-west1\"],\"labels\":{\"application\":\"agora\",\"environment\":\"production\",\"managed-by\":\"opentofu\",\"plane\":\"workload\",\"role\":\"database-snapshot\"}}]\n" "${snapshot_auto_created}" "${snapshot_time}"' \
    'fi' \
    >"${MOCK_BIN}/gcloud"
chmod 0700 "${MOCK_BIN}/gcloud"

DUMMY_DIGEST="$(printf 'a%.0s' {1..64})"
JSON_KEYS_IMAGE="europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/database@sha256:${DUMMY_DIGEST}"
AUTHENTICATION_IMAGE="europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/database@sha256:${DUMMY_DIGEST}"

PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    "${REPOSITORY_ROOT}/ops/deploy-database-release.sh" \
    agora-production-test \
    europe-west1-c \
    0123456789abcdef0123456789abcdef01234567 \
    "${JSON_KEYS_IMAGE}" \
    "${AUTHENTICATION_IMAGE}" \
    7 \
    11 \
    13 \
    17 \
    >"${TEMP_DIR}/database-release.out"

assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "7"
grep -Fqx 'describe' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'snapshots' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'list' "${GCLOUD_ARGUMENT_LOG}"
assert_equal "$(grep -Fc 'execute' "${GCLOUD_ARGUMENT_LOG}")" "2"
grep -Fqx 'agora-postgres-backup-json-keys' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'agora-postgres-backup-authentication' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--wait' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'all-instances-config' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'update-instances' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'wait-until' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--stable' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--timeout=600' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--format=json(allInstancesConfig.properties.metadata)' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--all-instances' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--minimal-action=restart' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--most-disruptive-allowed-action=restart' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- "--metadata=agora-database-release-revision=0123456789abcdef0123456789abcdef01234567,agora-json-keys-database-image=${JSON_KEYS_IMAGE},agora-authentication-database-image=${AUTHENTICATION_IMAGE},agora-json-keys-postgres-password-version=7,agora-authentication-postgres-password-version=11,agora-json-keys-postgres-backup-password-version=13,agora-authentication-postgres-backup-password-version=17" "${GCLOUD_ARGUMENT_LOG}"

# The first release has no source cluster to dump. It still requires the fresh
# scheduled snapshot and returns before attempting a nonexistent backup job.
: >"${GCLOUD_ARGUMENT_LOG}"
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    INITIAL_DATABASE_RELEASE=true \
    "${REPOSITORY_ROOT}/ops/prepare-database-change.sh" \
    agora-production-test \
    europe-west1-c \
    0123456789abcdef0123456789abcdef01234567 \
    >"${TEMP_DIR}/initial-database-gate.out"
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "2"
if grep -Fqx 'execute' "${GCLOUD_ARGUMENT_LOG}"; then
    printf "The empty first release must not attempt a logical backup.\n" >&2
    exit 1
fi

# The protected preflight binds the complete seven-field live map to the latest
# receipt without writing any individual metadata value to its proof or logs.
: >"${GCLOUD_ARGUMENT_LOG}"
INITIAL_DATABASE_PROOF="${TEMP_DIR}/initial-database-proof.json"
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    INITIAL_DATABASE_RELEASE=true \
    "${REPOSITORY_ROOT}/ops/prepare-database-change.sh" \
    agora-production-test \
    europe-west1-c \
    0123456789abcdef0123456789abcdef01234567 \
    "${INITIAL_DATABASE_PROOF}" \
    >"${TEMP_DIR}/initial-database-proof.out"
jq --exit-status '
  keys == ["checkedAt", "currentMetadataSha256", "project", "revision", "zone"] and
  (.currentMetadataSha256 | test("^[a-f0-9]{64}$"))
' "${INITIAL_DATABASE_PROOF}" >/dev/null

: >"${GCLOUD_ARGUMENT_LOG}"
set +e
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    INITIAL_DATABASE_RELEASE=true \
    "${REPOSITORY_ROOT}/ops/prepare-database-change.sh" \
    agora-production-test \
    europe-west1-c \
    0123456789abcdef0123456789abcdef01234567 \
    "${TEMP_DIR}/rejected-database-proof.json" \
    ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
    >/dev/null 2>&1
DATABASE_RECEIPT_DRIFT_CODE=$?
set -e
assert_equal "${DATABASE_RECEIPT_DRIFT_CODE}" 70
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" 1
if grep -Eq '^(snapshots|execute|all-instances-config|update-instances)$' \
    "${GCLOUD_ARGUMENT_LOG}"; then
    printf 'Receipt drift must fail before backup or database mutation.\n' >&2
    exit 1
fi

: >"${GCLOUD_ARGUMENT_LOG}"
set +e
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    "${REPOSITORY_ROOT}/ops/deploy-database-release.sh" \
    agora-production-test \
    europe-west1-c \
    abbreviated \
    "${JSON_KEYS_IMAGE}" \
    "${AUTHENTICATION_IMAGE}" \
    7 \
    11 \
    13 \
    17 \
    >"${TEMP_DIR}/invalid-database-release.out" \
    2>"${TEMP_DIR}/invalid-database-release.err"
INVALID_DATABASE_RELEASE_CODE=$?
set -e
assert_equal "${INVALID_DATABASE_RELEASE_CODE}" "65"
assert_equal "$(wc -c < "${GCLOUD_ARGUMENT_LOG}")" "0"

# Existing metadata must have the exact foundation-owned schema. Refuse to
# merge release fields into an unexpected map that OpenTofu intentionally
# ignores after the initial seed.
: >"${GCLOUD_ARGUMENT_LOG}"
set +e
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    INVALID_METADATA_SHAPE=true \
    "${REPOSITORY_ROOT}/ops/deploy-database-release.sh" \
    agora-production-test \
    europe-west1-c \
    0123456789abcdef0123456789abcdef01234567 \
    "${JSON_KEYS_IMAGE}" \
    "${AUTHENTICATION_IMAGE}" \
    7 \
    11 \
    13 \
    17 \
    >"${TEMP_DIR}/invalid-database-metadata.out" \
    2>"${TEMP_DIR}/invalid-database-metadata.err"
INVALID_DATABASE_METADATA_CODE=$?
set -e
assert_equal "${INVALID_DATABASE_METADATA_CODE}" "70"
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "1"
if grep -Eq '^(all-instances-config|update-instances)$' "${GCLOUD_ARGUMENT_LOG}"; then
    printf "Unexpected database metadata must fail before a mutation.\n" >&2
    exit 1
fi

# A database change is blocked outside the six-hour scheduled-snapshot window,
# before a logical backup or metadata mutation can begin.
: >"${GCLOUD_ARGUMENT_LOG}"
set +e
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    STALE_SNAPSHOT=true \
    "${REPOSITORY_ROOT}/ops/deploy-database-release.sh" \
    agora-production-test \
    europe-west1-c \
    0123456789abcdef0123456789abcdef01234567 \
    "${JSON_KEYS_IMAGE}" \
    "${AUTHENTICATION_IMAGE}" \
    7 \
    11 \
    13 \
    17 \
    >"${TEMP_DIR}/stale-database-snapshot.out" \
    2>"${TEMP_DIR}/stale-database-snapshot.err"
STALE_DATABASE_SNAPSHOT_CODE=$?
set -e
assert_equal "${STALE_DATABASE_SNAPSHOT_CODE}" "70"
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "2"
if grep -Eq '^(execute|all-instances-config|update-instances)$' "${GCLOUD_ARGUMENT_LOG}"; then
    printf "A stale snapshot must fail before backup or database mutation.\n" >&2
    exit 1
fi

# Matching labels cannot make an operator-created snapshot satisfy the
# code-owned schedule gate.
: >"${GCLOUD_ARGUMENT_LOG}"
set +e
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    INITIAL_DATABASE_RELEASE=true \
    MANUAL_SNAPSHOT=true \
    "${REPOSITORY_ROOT}/ops/prepare-database-change.sh" \
    agora-production-test \
    europe-west1-c \
    0123456789abcdef0123456789abcdef01234567 \
    >"${TEMP_DIR}/manual-database-snapshot.out" \
    2>"${TEMP_DIR}/manual-database-snapshot.err"
MANUAL_DATABASE_SNAPSHOT_CODE=$?
set -e
assert_equal "${MANUAL_DATABASE_SNAPSHOT_CODE}" "70"
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "2"
if grep -Eq '^(execute|all-instances-config|update-instances)$' "${GCLOUD_ARGUMENT_LOG}"; then
    printf "A manual snapshot must fail before backup or database mutation.\n" >&2
    exit 1
fi

# Every failure boundary after the first possibly partial database rollout has
# one compensation edge. Preflight and registry promotion cannot affect serving
# state and therefore do not invoke rollback.
RELEASE_DRIVER="${SCRIPT_DIR}/fixtures/fake-release-driver.sh"
RELEASE_STEPS=(
    preflight
    promote
    database
    candidate
    json-migrations
    json-rotation
    authentication-migrations
    recovery-verification
    authentication-initialization
    json-smoke
    json-traffic
    authentication-smoke
    authentication-traffic
    active
    receipt
)

for failed_step in "${RELEASE_STEPS[@]}"; do
    RELEASE_TEST_LOG="${TEMP_DIR}/release-${failed_step}.log"
    set +e
    RELEASE_TEST_LOG="${RELEASE_TEST_LOG}" \
        RELEASE_TEST_FAIL_STEP="${failed_step}" \
        "${REPOSITORY_ROOT}/ops/release-orchestrator.sh" "${RELEASE_DRIVER}" \
        >"${TEMP_DIR}/release-${failed_step}.out" \
        2>"${TEMP_DIR}/release-${failed_step}.err"
    RELEASE_CODE=$?
    set -e
    assert_equal "${RELEASE_CODE}" "42"
    if [ "${failed_step}" = preflight ] || [ "${failed_step}" = promote ]; then
        if grep -Fqx rollback "${RELEASE_TEST_LOG}"; then
            printf 'Read-only release failure unexpectedly requested rollback.\n' >&2
            exit 1
        fi
    else
        assert_equal "$(tail -n 1 "${RELEASE_TEST_LOG}")" rollback
        assert_equal "$(grep -Fxc rollback "${RELEASE_TEST_LOG}")" "1"
    fi
done

RELEASE_TEST_LOG="${TEMP_DIR}/release-success.log"
RELEASE_TEST_LOG="${RELEASE_TEST_LOG}" \
    "${REPOSITORY_ROOT}/ops/release-orchestrator.sh" "${RELEASE_DRIVER}" \
    >"${TEMP_DIR}/release-success.out"
assert_equal "$(paste -sd, "${RELEASE_TEST_LOG}")" \
    "$(IFS=,; printf '%s' "${RELEASE_STEPS[*]}")"

for release_job in \
    agora-json-keys-migrations \
    agora-json-keys-rotatekeys \
    agora-authentication-migrations \
    agora-postgres-backup-json-keys \
    agora-postgres-backup-authentication \
    agora-postgres-restore-json-keys \
    agora-postgres-restore-authentication \
    agora-postgres-backup-monitor; do
    if ! grep -Fq "run_job ${release_job}" \
        "${REPOSITORY_ROOT}/ops/google-release-driver.sh"; then
        printf 'The release driver job name differs from its declared Cloud Run job.\n' >&2
        exit 1
    fi
done
for service_contract in \
    "AUTHENTICATION_SERVICE='agora-authentication-rest'" \
    "JSON_KEYS_SERVICE='agora-json-keys-grpc'"; do
    if ! grep -Fqx "${service_contract}" \
        "${REPOSITORY_ROOT}/ops/google-release-driver.sh"; then
        printf 'The release driver service name differs from its declared Cloud Run service.\n' >&2
        exit 1
    fi
done
if grep -Fq 'run_job agora-authentication-init' \
    "${REPOSITORY_ROOT}/ops/google-release-driver.sh"; then
    printf 'Authentication initialization must not have an automated driver edge.\n' >&2
    exit 1
fi
if ! grep -Fq ".currentDatabase as \$database" \
    "${REPOSITORY_ROOT}/ops/google-release-driver.sh" ||
    grep -Fq ".previousDatabase as \$database" \
        "${REPOSITORY_ROOT}/ops/google-release-driver.sh"; then
    printf 'Release preflight must compare live metadata with the current receipt, not the rollback target.\n' >&2
    exit 1
fi

# Authentication initialization is a one-time observation gate, never an
# automated invocation. Exercise durable-marker, absent, failed, stale, and
# wrong-job outcomes with a zero-wait fake Cloud Run control plane.
INIT_MOCK_BIN="${TEMP_DIR}/init-bin"
mkdir -p "${INIT_MOCK_BIN}"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'if [ "$1 $2 $3" = "storage objects list" ]; then' \
    '    if [ "${INIT_LIST_FAILURE:-false}" = true ]; then exit 1; fi' \
    '    if [ "${INIT_EXISTING_MARKER:-false}" = true ]; then printf "%s\n" "gs://agora-receipts-test/production/initialization/complete.json"; fi' \
    'elif [ "$1 $2" = "storage cp" ] && [[ "$3" == gs://* ]]; then' \
    '    if [ "${INIT_EXISTING_MARKER:-false}" != true ]; then exit 1; fi' \
    '    printf "%s\n" "${INIT_MARKER_JSON}" >"$4"' \
    'elif [ "$1 $2 $3 $4" = "run jobs executions list" ]; then' \
    '    printf "%s\n" "${INIT_EXECUTIONS_JSON:-[]}"' \
    'elif [ "$1 $2" = "storage cp" ] && [[ "$4" == gs://* ]]; then' \
    '    printf "uploaded\n" >>"${INIT_UPLOAD_LOG}"' \
    'else' \
    '    exit 1' \
    'fi' \
    >"${INIT_MOCK_BIN}/gcloud"
chmod 0700 "${INIT_MOCK_BIN}/gcloud"

INIT_MARKER_JSON='{"schemaVersion":1,"commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","execution":"agora-authentication-init-valid","completedAt":"2026-08-25T12:00:00Z"}'
INIT_UPLOAD_LOG="${TEMP_DIR}/init-upload.log"
PATH="${INIT_MOCK_BIN}:${PATH}" \
    INIT_EXISTING_MARKER=true \
    INIT_MARKER_JSON="${INIT_MARKER_JSON}" \
    INIT_UPLOAD_LOG="${INIT_UPLOAD_LOG}" \
    "${REPOSITORY_ROOT}/ops/await-auth-initialization.sh" \
    agora-production-test europe-west1 agora-receipts-test \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >"${TEMP_DIR}/init-existing.out"
assert_equal "$(<"${TEMP_DIR}/init-existing.out")" agora-authentication-init-valid

set +e
PATH="${INIT_MOCK_BIN}:${PATH}" \
    INIT_LIST_FAILURE=true \
    INIT_MARKER_JSON="${INIT_MARKER_JSON}" \
    INIT_UPLOAD_LOG="${INIT_UPLOAD_LOG}" \
    "${REPOSITORY_ROOT}/ops/await-auth-initialization.sh" \
    agora-production-test europe-west1 agora-receipts-test \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >/dev/null 2>&1
INIT_LIST_FAILURE_CODE=$?
set -e
assert_equal "${INIT_LIST_FAILURE_CODE}" 70

run_failed_init_case() {
    local label="$1"
    local executions="$2"
    local code=0
    set +e
    PATH="${INIT_MOCK_BIN}:${PATH}" \
        INITIALIZATION_MAX_POLLS=1 \
        INITIALIZATION_POLL_SECONDS=0 \
        INIT_EXECUTIONS_JSON="${executions}" \
        INIT_MARKER_JSON="${INIT_MARKER_JSON}" \
        INIT_UPLOAD_LOG="${INIT_UPLOAD_LOG}" \
        "${REPOSITORY_ROOT}/ops/await-auth-initialization.sh" \
        agora-production-test europe-west1 agora-receipts-test \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        >"${TEMP_DIR}/init-${label}.out" \
        2>"${TEMP_DIR}/init-${label}.err"
    code=$?
    set -e
    assert_equal "${code}" 70
}

run_failed_init_case absent '[]'
run_failed_init_case failed '[{"metadata":{"name":"agora-authentication-init-failed","creationTimestamp":"9999-01-01T00:00:00Z"},"status":{"conditions":[{"type":"Completed","status":"False"}]}}]'
run_failed_init_case stale '[{"metadata":{"name":"agora-authentication-init-stale","creationTimestamp":"2000-01-01T00:00:00Z"},"status":{"conditions":[{"type":"Completed","status":"True"}]}}]'
run_failed_init_case wrong-job '[{"metadata":{"name":"different-job-success","creationTimestamp":"9999-01-01T00:00:00Z"},"status":{"conditions":[{"type":"Completed","status":"True"}]}}]'

: >"${INIT_UPLOAD_LOG}"
PATH="${INIT_MOCK_BIN}:${PATH}" \
    INITIALIZATION_MAX_POLLS=1 \
    INITIALIZATION_POLL_SECONDS=0 \
    INIT_EXECUTIONS_JSON='[{"metadata":{"name":"agora-authentication-init-success","creationTimestamp":"9999-01-01T00:00:00Z"},"status":{"conditions":[{"type":"Completed","status":"True"}]}}]' \
    INIT_MARKER_JSON="${INIT_MARKER_JSON}" \
    INIT_UPLOAD_LOG="${INIT_UPLOAD_LOG}" \
    "${REPOSITORY_ROOT}/ops/await-auth-initialization.sh" \
    agora-production-test europe-west1 agora-receipts-test \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >"${TEMP_DIR}/init-success.out" 2>"${TEMP_DIR}/init-success.err"
assert_equal "$(<"${TEMP_DIR}/init-success.out")" agora-authentication-init-success
assert_equal "$(grep -Fc uploaded "${INIT_UPLOAD_LOG}")" 1

# Opaque plan custody binds the binary to its root, commit, state suffix, hash,
# and expiry. Consumption removes the live object, preventing replay.
STORAGE_MOCK_BIN="${TEMP_DIR}/storage-bin"
FAKE_GCS_ROOT="${TEMP_DIR}/gcs"
mkdir -p "${STORAGE_MOCK_BIN}" "${FAKE_GCS_ROOT}"
ln -s "${SCRIPT_DIR}/fixtures/fake-gcloud-storage.sh" "${STORAGE_MOCK_BIN}/gcloud"
PLAN_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# Recovery evidence contains timestamps and ages only. It never copies backup
# manifests or database payloads into logs or the immutable recovery receipt.
RECOVERY_NOW="$(date -u +%s)"
JSON_KEYS_COMPLETED="$((RECOVERY_NOW - 600))"
AUTHENTICATION_COMPLETED="$((RECOVERY_NOW - 1200))"
JSON_KEYS_ATTEMPT="${JSON_KEYS_COMPLETED}-json-keys-backup-1"
AUTHENTICATION_ATTEMPT="${AUTHENTICATION_COMPLETED}-authentication-backup-1"
JSON_KEYS_IMAGE='ghcr.io/a-novel/service-json-keys/database@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
AUTHENTICATION_IMAGE='ghcr.io/a-novel/service-authentication/database@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

write_recovery_manifest() {
    local key="$1"
    local attempt="$2"
    local image="$3"
    local completed="$4"
    local directory="${FAKE_GCS_ROOT}/agora-backups-test/v1/${key}/attempts/${attempt}"
    mkdir -p "${directory}"
    printf '%s\n' \
        'format=agora-postgres-backup-v1' \
        "database_key=${key}" \
        'source_project=agora-production-source' \
        'source_host=private-host' \
        'source_port=5432' \
        "source_database=${key}" \
        'source_owner=agora' \
        'backup_role=agora_backup' \
        "database_image=${image}" \
        'postgres_major=18' \
        'pg_dump_version=18.0' \
        "started_epoch=$((completed - 60))" \
        "completed_epoch=${completed}" \
        "dump_object=v1/${key}/attempts/${attempt}/database.dump" \
        'dump_size_bytes=1024' \
        'dump_sha256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
        "execution=${key}-backup" \
        'task_attempt=1' \
        >"${directory}/completed.manifest"
}

write_recovery_manifest json-keys "${JSON_KEYS_ATTEMPT}" \
    "${JSON_KEYS_IMAGE}" "${JSON_KEYS_COMPLETED}"
write_recovery_manifest authentication "${AUTHENTICATION_ATTEMPT}" \
    "${AUTHENTICATION_IMAGE}" "${AUTHENTICATION_COMPLETED}"
jq -n --arg json_image "${JSON_KEYS_IMAGE}" \
    --arg authentication_image "${AUTHENTICATION_IMAGE}" '
      {
        activeTfvars: {workload_project_id: "agora-production-source"},
        database: {
          jsonKeysImage: $json_image,
          authenticationImage: $authentication_image
        }
      }
    ' >"${TEMP_DIR}/recovery-source-receipt.json"
PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    "${REPOSITORY_ROOT}/ops/verify-recovery-points.sh" \
    agora-backups-test "${TEMP_DIR}/recovery-source-receipt.json" \
    "${JSON_KEYS_ATTEMPT}" "${AUTHENTICATION_ATTEMPT}" \
    "${TEMP_DIR}/recovery-points.json" >"${TEMP_DIR}/recovery-points.out"
jq --exit-status '
  .schemaVersion == 1 and
  (.databases.jsonKeys.ageSeconds >= 600 and .databases.jsonKeys.ageSeconds <= 610) and
  (.databases.authentication.ageSeconds >= 1200 and .databases.authentication.ageSeconds <= 1210) and
  .maxLostWriteWindowSeconds == .databases.authentication.ageSeconds
' "${TEMP_DIR}/recovery-points.json" >/dev/null
assert_equal "$(stat -c '%a' "${TEMP_DIR}/recovery-points.json")" 600

# A tolerated future completion time represents clock skew, not a negative RPO.
FUTURE_COMPLETED="$((RECOVERY_NOW + 240))"
FUTURE_ATTEMPT="${FUTURE_COMPLETED}-json-keys-backup-1"
write_recovery_manifest json-keys "${FUTURE_ATTEMPT}" \
    "${JSON_KEYS_IMAGE}" "${FUTURE_COMPLETED}"
PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    "${REPOSITORY_ROOT}/ops/verify-recovery-points.sh" \
    agora-backups-test "${TEMP_DIR}/recovery-source-receipt.json" \
    "${FUTURE_ATTEMPT}" "${AUTHENTICATION_ATTEMPT}" \
    "${TEMP_DIR}/recovery-points-skew.json" >/dev/null
jq --exit-status '.databases.jsonKeys.ageSeconds == 0' \
    "${TEMP_DIR}/recovery-points-skew.json" >/dev/null

printf 'opaque-plan-fixture' >"${TEMP_DIR}/plan.tfplan"
PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    TOFU_STATE_SUFFIX=recovery/agora-recovery-test \
    "${REPOSITORY_ROOT}/ops/plan-custody.sh" publish \
    agora-state-test foundation "${PLAN_COMMIT}" 101-1 \
    "${TEMP_DIR}/plan.tfplan" false >"${TEMP_DIR}/plan-publish.out"
PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    TOFU_STATE_SUFFIX=recovery/agora-recovery-test \
    "${REPOSITORY_ROOT}/ops/plan-custody.sh" fetch \
    agora-state-test foundation "${PLAN_COMMIT}" 101-1 \
    "${TEMP_DIR}/fetched.tfplan" >"${TEMP_DIR}/plan-fetch.out"
assert_equal "$(sha256sum "${TEMP_DIR}/plan.tfplan" | cut -d ' ' -f 1)" \
    "$(sha256sum "${TEMP_DIR}/fetched.tfplan" | cut -d ' ' -f 1)"
assert_equal "$(<"${TEMP_DIR}/fetched.tfplan.destructive")" false

set +e
PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    TOFU_STATE_SUFFIX=recovery/different-recovery \
    "${REPOSITORY_ROOT}/ops/plan-custody.sh" fetch \
    agora-state-test foundation "${PLAN_COMMIT}" 101-1 \
    "${TEMP_DIR}/mismatched.tfplan" >/dev/null 2>&1
MISMATCHED_PLAN_CODE=$?
set -e
assert_equal "${MISMATCHED_PLAN_CODE}" 66

PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    TOFU_STATE_SUFFIX=recovery/agora-recovery-test \
    "${REPOSITORY_ROOT}/ops/plan-custody.sh" consume \
    agora-state-test foundation "${PLAN_COMMIT}" 101-1 \
    >"${TEMP_DIR}/plan-consume.out"
set +e
PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    TOFU_STATE_SUFFIX=recovery/agora-recovery-test \
    "${REPOSITORY_ROOT}/ops/plan-custody.sh" fetch \
    agora-state-test foundation "${PLAN_COMMIT}" 101-1 \
    "${TEMP_DIR}/replayed.tfplan" >/dev/null 2>&1
REPLAYED_PLAN_CODE=$?
set -e
assert_equal "${REPLAYED_PLAN_CODE}" 66

# Private desired-state lookup distinguishes a confirmed empty inventory from
# a storage failure, so scheduled drift never silently skips a configured root.
set +e
PATH="${STORAGE_MOCK_BIN}:${PATH}" \
    FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    FAKE_GCS_LIST_FAILURE=true \
    "${REPOSITORY_ROOT}/ops/config-custody.sh" fetch \
    agora-state-test foundation "${TEMP_DIR}/unavailable-config.json" \
    >/dev/null 2>&1
UNAVAILABLE_CONFIG_CODE=$?
set -e
assert_equal "${UNAVAILABLE_CONFIG_CODE}" 70

# Applying must consume custody before OpenTofu receives the local binary. If
# apply later fails, the operator must create a fresh reviewed plan instead of
# replaying a plan whose mutation status may be ambiguous.
printf 'opaque-apply-plan-fixture' >"${TEMP_DIR}/apply-plan.tfplan"
printf '{}\n' >"${TEMP_DIR}/release-config.json"
PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    "${REPOSITORY_ROOT}/ops/plan-custody.sh" publish \
    agora-state-test foundation "${PLAN_COMMIT}" 202-1 \
    "${TEMP_DIR}/apply-plan.tfplan" false >"${TEMP_DIR}/apply-plan-publish.out"
ln -s "${SCRIPT_DIR}/fixtures/fake-tofu.sh" "${STORAGE_MOCK_BIN}/tofu"
printf '%s\n' '#!/bin/bash' 'exit 0' >"${STORAGE_MOCK_BIN}/git"
chmod 0700 "${STORAGE_MOCK_BIN}/git"
APPLY_PLAN_OBJECT="${FAKE_GCS_ROOT}/agora-state-test/foundation/plans/${PLAN_COMMIT}/202-1/plan.tfplan"
PATH="${STORAGE_MOCK_BIN}:${PATH}" \
    FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    FAKE_TOFU_PLAN_CODE=0 \
    FAKE_TOFU_PLAN_JSON="${SCRIPT_DIR}/fixtures/plans/safe.json" \
    FAKE_TOFU_REQUIRE_ABSENT="${APPLY_PLAN_OBJECT}" \
    GITHUB_REPOSITORY=a-novel/infra \
    "${REPOSITORY_ROOT}/ops/apply-reviewed-plan.sh" \
    foundation agora-state-test "${PLAN_COMMIT}" 202-1 \
    "${TEMP_DIR}/release-config.json" >"${TEMP_DIR}/apply-reviewed-plan.out"
if [ -e "${APPLY_PLAN_OBJECT}" ]; then
    printf 'Consumed saved plan remained available after apply.\n' >&2
    exit 1
fi

# An immutable newer deployment receipt wins over a delayed older workflow.
set +e
PATH="${STORAGE_MOCK_BIN}:${PATH}" \
    FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    FAKE_GCS_LIST_FAILURE=true \
    "${REPOSITORY_ROOT}/ops/receipt-custody.sh" latest \
    agora-receipts-test "${TEMP_DIR}/unavailable-receipt.json" \
    >/dev/null 2>&1
UNAVAILABLE_RECEIPT_CODE=$?
set -e
assert_equal "${UNAVAILABLE_RECEIPT_CODE}" 70

make_receipt() {
    local run_id="$1"
    local output="$2"
    jq -n --arg run_id "${run_id}" --arg commit "${PLAN_COMMIT}" '
      {
        schemaVersion: 1,
        kind: "deployment",
        createdAt: "2026-08-25T12:00:00Z",
        sequence: {runId: $run_id, runAttempt: 1},
        source: {commit: $commit, manifestSha256: ("b" * 64)},
        activeTfvars: {},
        database: null,
        operations: {
          executions: {
            jsonKeysMigrations: null,
            jsonKeysRotation: null,
            authenticationMigrations: null,
            postgresBackupJsonKeys: null,
            postgresBackupAuthentication: null,
            postgresRestoreJsonKeys: null,
            postgresRestoreAuthentication: null,
            postgresBackupMonitor: null
          },
          initialization: null,
          health: {jsonKeys: "not-run", authentication: "not-run"}
        }
      }
    ' >"${output}"
}

make_receipt 200 "${TEMP_DIR}/receipt-200.json"
PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    "${REPOSITORY_ROOT}/ops/receipt-custody.sh" publish \
    agora-receipts-test "${TEMP_DIR}/receipt-200.json" 200 1 \
    >"${TEMP_DIR}/receipt-200.out"
jq '.sequence.runAttempt = 2' "${TEMP_DIR}/receipt-200.json" \
    >"${TEMP_DIR}/receipt-200-attempt-2.json"
PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    "${REPOSITORY_ROOT}/ops/receipt-custody.sh" publish \
    agora-receipts-test "${TEMP_DIR}/receipt-200-attempt-2.json" 200 2 \
    >"${TEMP_DIR}/receipt-200-attempt-2.out"
PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    "${REPOSITORY_ROOT}/ops/receipt-custody.sh" fetch \
    agora-receipts-test "${TEMP_DIR}/receipt-200-fetched.json" 200-2
assert_equal "$(jq --raw-output .sequence.runAttempt "${TEMP_DIR}/receipt-200-fetched.json")" 2
make_receipt 100 "${TEMP_DIR}/receipt-100.json"
set +e
PATH="${STORAGE_MOCK_BIN}:${PATH}" FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    "${REPOSITORY_ROOT}/ops/receipt-custody.sh" publish \
    agora-receipts-test "${TEMP_DIR}/receipt-100.json" 100 1 \
    >"${TEMP_DIR}/receipt-100.out" 2>"${TEMP_DIR}/receipt-100.err"
STALE_RECEIPT_CODE=$?
set -e
assert_equal "${STALE_RECEIPT_CODE}" 70

# A lost create response is idempotent only when the immutable object that
# actually landed is byte-for-byte identical to the local receipt.
make_receipt 300 "${TEMP_DIR}/receipt-300.json"
PATH="${STORAGE_MOCK_BIN}:${PATH}" \
    FAKE_GCS_ROOT="${FAKE_GCS_ROOT}" \
    FAKE_GCS_LOST_UPLOAD_RESPONSE=true \
    "${REPOSITORY_ROOT}/ops/receipt-custody.sh" publish \
    agora-receipts-test "${TEMP_DIR}/receipt-300.json" 300 1 \
    >"${TEMP_DIR}/receipt-300.out"
grep -Fq 'Immutable production release receipt published.' \
    "${TEMP_DIR}/receipt-300.out"

# Protected workflow dispatch must resolve exactly the newly created master run,
# wait for it, and emit only the identifier requested by the operator.
WORKFLOW_MOCK_BIN="${TEMP_DIR}/workflow-bin"
mkdir -p "${WORKFLOW_MOCK_BIN}"
ln -s "${SCRIPT_DIR}/fixtures/fake-workflow-gh.sh" "${WORKFLOW_MOCK_BIN}/gh"
ln -s "${SCRIPT_DIR}/fixtures/fake-workflow-git.sh" "${WORKFLOW_MOCK_BIN}/git"
WORKFLOW_STATE="${TEMP_DIR}/workflow-state"
WORKFLOW_CALLS="${TEMP_DIR}/workflow-calls"
WORKFLOW_SHA='1234567890abcdef1234567890abcdef12345678'

PLAN_ID="$(
    PATH="${WORKFLOW_MOCK_BIN}:${PATH}" \
        FAKE_WORKFLOW_CALLS="${WORKFLOW_CALLS}" \
        FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
        FAKE_WORKFLOW_STATE="${WORKFLOW_STATE}" \
        WORKFLOW_DISCOVERY_ATTEMPTS=1 \
        WORKFLOW_DISCOVERY_INTERVAL_SECONDS=0 \
        "${REPOSITORY_ROOT}/ops/run-workflow.sh" \
            foundation plan foundation \
            2>"${TEMP_DIR}/workflow.err"
)"
assert_equal "${PLAN_ID}" '202-3'
grep -Fq 'Workflow run: https://github.com/a-novel/infra/actions/runs/202' \
    "${TEMP_DIR}/workflow.err"
grep -Fq 'workflow run foundation.yaml --repo a-novel/infra --ref master -f operation=plan -f root=foundation' \
    "${WORKFLOW_CALLS}"

rm -f -- "${WORKFLOW_STATE}"
: >"${WORKFLOW_CALLS}"
DETACHED_RUN_ID="$(
    PATH="${WORKFLOW_MOCK_BIN}:${PATH}" \
        FAKE_WORKFLOW_CALLS="${WORKFLOW_CALLS}" \
        FAKE_WORKFLOW=release.yaml \
        FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
        FAKE_WORKFLOW_STATE="${WORKFLOW_STATE}" \
        WORKFLOW_DISCOVERY_ATTEMPTS=1 \
        WORKFLOW_DISCOVERY_INTERVAL_SECONDS=0 \
        "${REPOSITORY_ROOT}/ops/run-workflow.sh" \
            release deploy --no-wait \
            2>"${TEMP_DIR}/detached-workflow.err"
)"
assert_equal "${DETACHED_RUN_ID}" 202
if grep -Fq 'run watch' "${WORKFLOW_CALLS}"; then
    printf 'A detached workflow dispatch unexpectedly started a watcher.\n' >&2
    exit 1
fi

rm -f -- "${WORKFLOW_STATE}"
: >"${WORKFLOW_CALLS}"
RECOVERY_RUN_REF="$(
    PATH="${WORKFLOW_MOCK_BIN}:${PATH}" \
        FAKE_WORKFLOW_CALLS="${WORKFLOW_CALLS}" \
        FAKE_WORKFLOW=recovery.yaml \
        FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
        FAKE_WORKFLOW_STATE="${WORKFLOW_STATE}" \
        WORKFLOW_DISCOVERY_ATTEMPTS=1 \
        WORKFLOW_DISCOVERY_INTERVAL_SECONDS=0 \
        "${REPOSITORY_ROOT}/ops/run-workflow.sh" recovery restore-data \
            recovery-project-prod 202-3 \
            100-json-1 101-authentication-1 \
            'no known lost writes' 'RESTORE recovery-project-prod' \
            2>"${TEMP_DIR}/recovery-workflow.err"
)"
assert_equal "${RECOVERY_RUN_REF}" 202-3
grep -Fq 'workflow run recovery.yaml --repo a-novel/infra --ref master -f operation=restore-data -f replacement_project_id=recovery-project-prod -f target_receipt=202-3' \
    "${WORKFLOW_CALLS}"
grep -Fq -- '-f json_keys_attempt=100-json-1 -f authentication_attempt=101-authentication-1' \
    "${WORKFLOW_CALLS}"
grep -Fq -- '-f lost_write_window=no known lost writes -f confirm=RESTORE recovery-project-prod' \
    "${WORKFLOW_CALLS}"

rm -f -- "${WORKFLOW_STATE}"
: >"${WORKFLOW_CALLS}"
APPLY_RUN_ID="$(
    PATH="${WORKFLOW_MOCK_BIN}:${PATH}" \
        FAKE_WORKFLOW_CALLS="${WORKFLOW_CALLS}" \
        FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
        FAKE_WORKFLOW_STATE="${WORKFLOW_STATE}" \
        WORKFLOW_DISCOVERY_ATTEMPTS=1 \
        WORKFLOW_DISCOVERY_INTERVAL_SECONDS=0 \
        "${REPOSITORY_ROOT}/ops/run-workflow.sh" \
            foundation apply foundation 202-3 \
            2>"${TEMP_DIR}/apply-workflow.err"
)"
assert_equal "${APPLY_RUN_ID}" 202
grep -Fq \
    'workflow run foundation.yaml --repo a-novel/infra --ref master -f operation=apply -f root=foundation -f plan_id=202-3' \
    "${WORKFLOW_CALLS}"

rm -f -- "${WORKFLOW_STATE}"
: >"${WORKFLOW_CALLS}"
set +e
PATH="${WORKFLOW_MOCK_BIN}:${PATH}" \
    FAKE_PLAN_WORKFLOW_SHA='0000000000000000000000000000000000000000' \
    FAKE_WORKFLOW_CALLS="${WORKFLOW_CALLS}" \
    FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
    FAKE_WORKFLOW_STATE="${WORKFLOW_STATE}" \
    "${REPOSITORY_ROOT}/ops/run-workflow.sh" \
        foundation apply foundation 202-3 \
        >"${TEMP_DIR}/stale-plan.out" 2>"${TEMP_DIR}/stale-plan.err"
STALE_PLAN_CODE=$?
set -e
assert_equal "${STALE_PLAN_CODE}" 65
grep -Fq 'selected plan commit is no longer the local master commit' \
    "${TEMP_DIR}/stale-plan.err"
if grep -Fq 'workflow run' "${WORKFLOW_CALLS}"; then
    printf 'A stale reviewed plan unexpectedly dispatched a workflow.\n' >&2
    exit 1
fi

rm -f -- "${WORKFLOW_STATE}"
: >"${WORKFLOW_CALLS}"
set +e
PATH="${WORKFLOW_MOCK_BIN}:${PATH}" \
    FAKE_PLAN_DISPLAY_TITLE='foundation apply foundation by @operator' \
    FAKE_WORKFLOW_CALLS="${WORKFLOW_CALLS}" \
    FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
    FAKE_WORKFLOW_STATE="${WORKFLOW_STATE}" \
    "${REPOSITORY_ROOT}/ops/run-workflow.sh" \
        foundation apply foundation 202-3 \
        >"${TEMP_DIR}/wrong-plan-kind.out" 2>"${TEMP_DIR}/wrong-plan-kind.err"
WRONG_PLAN_KIND_CODE=$?
set -e
assert_equal "${WRONG_PLAN_KIND_CODE}" 65
grep -Fq 'not a successful matching workflow attempt' \
    "${TEMP_DIR}/wrong-plan-kind.err"
if grep -Fq 'workflow run' "${WORKFLOW_CALLS}"; then
    printf 'A non-plan workflow attempt unexpectedly dispatched apply.\n' >&2
    exit 1
fi

rm -f -- "${WORKFLOW_STATE}"
: >"${WORKFLOW_CALLS}"
set +e
PATH="${WORKFLOW_MOCK_BIN}:${PATH}" \
    FAKE_ACTIVE_WORKFLOW=true \
    FAKE_WORKFLOW_CALLS="${WORKFLOW_CALLS}" \
    FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
    FAKE_WORKFLOW_STATE="${WORKFLOW_STATE}" \
    "${REPOSITORY_ROOT}/ops/run-workflow.sh" \
        foundation apply foundation 202-3 \
        >"${TEMP_DIR}/active-workflow.out" 2>"${TEMP_DIR}/active-workflow.err"
ACTIVE_WORKFLOW_CODE=$?
set -e
assert_equal "${ACTIVE_WORKFLOW_CODE}" 75
grep -Fq 'Another production infrastructure run is active' \
    "${TEMP_DIR}/active-workflow.err"
if grep -Fq 'workflow run' "${WORKFLOW_CALLS}"; then
    printf 'An active production workflow did not block dispatch.\n' >&2
    exit 1
fi

set +e
"${REPOSITORY_ROOT}/ops/run-workflow.sh" foundation plan \
    >/dev/null 2>&1
INVALID_WORKFLOW_INPUT_CODE=$?
set -e
assert_equal "${INVALID_WORKFLOW_INPUT_CODE}" 64

set +e
"${REPOSITORY_ROOT}/ops/run-workflow.sh" recovery restore-data \
    recovery-project-prod 202-3 \
    100-json-1 101-authentication-1 'no known lost writes' \
    'RESTORE wrong-project' >/dev/null 2>&1
INVALID_RECOVERY_CONFIRMATION_CODE=$?
INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
    INFRA_WORKLOAD_PROJECT_ID=INVALID \
    "${REPOSITORY_ROOT}/ops/foundation.sh" configure >/dev/null 2>&1
INVALID_FOUNDATION_PROJECT_CODE=$?
INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
    INFRA_WORKLOAD_PROJECT_ID=INVALID \
    "${REPOSITORY_ROOT}/ops/foundation-audit.sh" >/dev/null 2>&1
INVALID_FOUNDATION_AUDIT_PROJECT_CODE=$?
set -e
assert_equal "${INVALID_RECOVERY_CONFIRMATION_CODE}" 64
assert_equal "${INVALID_FOUNDATION_PROJECT_CODE}" 64
assert_equal "${INVALID_FOUNDATION_AUDIT_PROJECT_CODE}" 64

# Foundation configuration derives every coordinate in a fresh process, writes
# only the protected JSON document, and keeps billing/human metadata off stdout.
FOUNDATION_MOCK_BIN="${TEMP_DIR}/foundation-bin"
FOUNDATION_CALLS="${TEMP_DIR}/foundation-calls"
FOUNDATION_SECRETS="${TEMP_DIR}/foundation-secrets"
mkdir -p "${FOUNDATION_MOCK_BIN}"
ln -s "${SCRIPT_DIR}/fixtures/fake-foundation-gh.sh" "${FOUNDATION_MOCK_BIN}/gh"
ln -s "${SCRIPT_DIR}/fixtures/fake-foundation-gcloud.sh" "${FOUNDATION_MOCK_BIN}/gcloud"
ln -s "${SCRIPT_DIR}/fixtures/fake-workflow-git.sh" "${FOUNDATION_MOCK_BIN}/git"
: >"${FOUNDATION_CALLS}"
: >"${FOUNDATION_SECRETS}"
FOUNDATION_OUTPUT="$(
    PATH="${FOUNDATION_MOCK_BIN}:${PATH}" \
        FAKE_FOUNDATION_CALLS="${FOUNDATION_CALLS}" \
        FAKE_FOUNDATION_SECRETS="${FOUNDATION_SECRETS}" \
        FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
        INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
        INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
        "${REPOSITORY_ROOT}/ops/foundation.sh" configure
)"
grep -Fq 'PASS protected foundation environment' <<<"${FOUNDATION_OUTPUT}"
grep -Fq 'PASS protected foundation configuration' <<<"${FOUNDATION_OUTPUT}"
assert_equal "$(wc -l <"${FOUNDATION_SECRETS}" | tr -d ' ')" 2
grep -Fq -- '--env production-foundation' "${FOUNDATION_SECRETS}"
grep -Fq -- '--env production-recovery' "${FOUNDATION_SECRETS}"
grep -Fq '"workload_project_id":"workload-project-prod"' "${FOUNDATION_SECRETS}"
grep -Fq '"organization_id":"123456789012"' "${FOUNDATION_SECRETS}"
grep -Fq '"adopt_existing_project":false' "${FOUNDATION_SECRETS}"
if grep -Eq 'operator@example\.com|ABCDEF-123456-ABCDEF' <<<"${FOUNDATION_OUTPUT}"; then
    printf 'Protected foundation metadata leaked to stdout.\n' >&2
    exit 1
fi

set +e
PATH="${FOUNDATION_MOCK_BIN}:${PATH}" \
    FAKE_FOUNDATION_CALLS="${FOUNDATION_CALLS}" \
    FAKE_FOUNDATION_SECRETS="${FOUNDATION_SECRETS}" \
    FAKE_GIT_DIRTY=true \
    FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
    INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
    INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
    "${REPOSITORY_ROOT}/ops/foundation.sh" configure \
        >"${TEMP_DIR}/dirty-foundation.out" 2>"${TEMP_DIR}/dirty-foundation.err"
DIRTY_FOUNDATION_CODE=$?
set -e
assert_equal "${DIRTY_FOUNDATION_CODE}" 65
assert_equal "$(wc -l <"${FOUNDATION_SECRETS}" | tr -d ' ')" 2
grep -Fq 'requires a clean local master checkout' \
    "${TEMP_DIR}/dirty-foundation.err"

# Read-only audit access derives only the active human identity; it does not
# require unrelated billing, backup, or project-parent permissions.
: >"${FOUNDATION_CALLS}"
FOUNDATION_AUDIT_ACCESS_OUTPUT="$(
    PATH="${FOUNDATION_MOCK_BIN}:${PATH}" \
        FAKE_FOUNDATION_CALLS="${FOUNDATION_CALLS}" \
        FAKE_FOUNDATION_SECRETS="${FOUNDATION_SECRETS}" \
        FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
        INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
        INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
        "${REPOSITORY_ROOT}/ops/foundation.sh" grant-audit-access
)"
grep -Fq 'PASS temporary audit access' <<<"${FOUNDATION_AUDIT_ACCESS_OUTPUT}"
grep -Fq 'config get-value account' "${FOUNDATION_CALLS}"
grep -Fq 'projects get-iam-policy workload-project-prod' "${FOUNDATION_CALLS}"
if grep -Eq 'billing|GCP_BACKUP_BUCKET|parent\.(type|id)' "${FOUNDATION_CALLS}"; then
    printf 'Audit access loaded unrelated foundation context.\n' >&2
    exit 1
fi

# The audit accepts only managed APIs plus reviewed Google defaults and
# dependencies, while still reporting missing or unknown APIs precisely.
FOUNDATION_AUDIT_MOCK_BIN="${TEMP_DIR}/foundation-audit-bin"
mkdir -p "${FOUNDATION_AUDIT_MOCK_BIN}"
ln -s "${SCRIPT_DIR}/fixtures/fake-foundation-gh.sh" \
    "${FOUNDATION_AUDIT_MOCK_BIN}/gh"
ln -s "${SCRIPT_DIR}/fixtures/fake-foundation-audit-services-gcloud.sh" \
    "${FOUNDATION_AUDIT_MOCK_BIN}/gcloud"

assert_foundation_service_boundary() {
    local mode="$1"
    local expected_code="$2"
    local output_file="${TEMP_DIR}/foundation-audit-${mode}.out"
    local error_file="${TEMP_DIR}/foundation-audit-${mode}.err"
    local code=0

    : >"${FOUNDATION_CALLS}"
    set +e
    PATH="${FOUNDATION_AUDIT_MOCK_BIN}:${PATH}" \
        FAKE_FOUNDATION_CALLS="${FOUNDATION_CALLS}" \
        FAKE_FOUNDATION_SECRETS="${FOUNDATION_SECRETS}" \
        FAKE_FOUNDATION_SERVICE_MODE="$mode" \
        INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
        INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
        "${REPOSITORY_ROOT}/ops/foundation-audit.sh" \
        >"$output_file" 2>"$error_file"
    code=$?
    set -e
    assert_equal "$code" "$expected_code"
}

assert_foundation_service_boundary allowed 64
grep -Fq 'PASS enabled service boundary' \
    "${TEMP_DIR}/foundation-audit-allowed.out"
grep -Fq 'projects get-iam-policy workload-project-prod --format=json' \
    "${FOUNDATION_CALLS}"

assert_foundation_service_boundary missing 70
grep -Fq 'MISSING_API=run.googleapis.com' \
    "${TEMP_DIR}/foundation-audit-missing.err"
if grep -Fq 'projects get-iam-policy' "${FOUNDATION_CALLS}"; then
    printf 'A missing required API did not stop the foundation audit.\n' >&2
    exit 1
fi

assert_foundation_service_boundary unexpected 70
grep -Fq 'UNEXPECTED_API=unknown.googleapis.com' \
    "${TEMP_DIR}/foundation-audit-unexpected.err"
if grep -Fq 'projects get-iam-policy' "${FOUNDATION_CALLS}"; then
    printf 'An unknown API did not stop the foundation audit.\n' >&2
    exit 1
fi

# The one local bootstrap apply uses an external binary plan plus non-secret
# commit/checksum custody and consumes that review before mutation.
BOOTSTRAP_MOCK_BIN="${TEMP_DIR}/bootstrap-bin"
BOOTSTRAP_PLAN="${TEMP_DIR}/bootstrap-plan.tfplan"
BOOTSTRAP_CALLS="${TEMP_DIR}/bootstrap-calls"
BOOTSTRAP_STATE="${TEMP_DIR}/bootstrap-workflow-state"
mkdir -p "${BOOTSTRAP_MOCK_BIN}"
ln -s "${SCRIPT_DIR}/fixtures/fake-foundation-gcloud.sh" "${BOOTSTRAP_MOCK_BIN}/gcloud"
ln -s "${SCRIPT_DIR}/fixtures/fake-workflow-gh.sh" "${BOOTSTRAP_MOCK_BIN}/gh"
ln -s "${SCRIPT_DIR}/fixtures/fake-workflow-git.sh" "${BOOTSTRAP_MOCK_BIN}/git"
ln -s "${SCRIPT_DIR}/fixtures/fake-tofu.sh" "${BOOTSTRAP_MOCK_BIN}/tofu"
: >"${BOOTSTRAP_CALLS}"
set +e
PATH="${BOOTSTRAP_MOCK_BIN}:${PATH}" \
    FAKE_FOUNDATION_CALLS="${BOOTSTRAP_CALLS}" \
    FAKE_WORKFLOW_CALLS="${BOOTSTRAP_CALLS}" \
    FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
    FAKE_WORKFLOW_STATE="${BOOTSTRAP_STATE}" \
    FAKE_TOFU_PLAN_CODE=2 \
    FAKE_TOFU_PLAN_JSON="${SCRIPT_DIR}/fixtures/plans/safe.json" \
    INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
    INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
    "${REPOSITORY_ROOT}/ops/bootstrap-plan.sh" plan \
        "${BOOTSTRAP_PLAN}" \
        >"${TEMP_DIR}/bootstrap-plan.out" 2>"${TEMP_DIR}/bootstrap-plan.err"
BOOTSTRAP_PLAN_CODE=$?
set -e
assert_equal "${BOOTSTRAP_PLAN_CODE}" 2
test -f "${BOOTSTRAP_PLAN}"
test -f "${BOOTSTRAP_PLAN}.metadata.json"
jq --exit-status \
    --arg commit "${WORKFLOW_SHA}" '
      .schemaVersion == 1 and
      .root == "bootstrap" and
      .commit == $commit and
      .consumed == false
    ' "${BOOTSTRAP_PLAN}.metadata.json" >/dev/null

PATH="${BOOTSTRAP_MOCK_BIN}:${PATH}" \
    FAKE_FOUNDATION_CALLS="${BOOTSTRAP_CALLS}" \
    FAKE_WORKFLOW_CALLS="${BOOTSTRAP_CALLS}" \
    FAKE_WORKFLOW_SHA="${WORKFLOW_SHA}" \
    FAKE_WORKFLOW_STATE="${BOOTSTRAP_STATE}" \
    FAKE_TOFU_PLAN_CODE=0 \
    FAKE_TOFU_PLAN_JSON="${SCRIPT_DIR}/fixtures/plans/safe.json" \
    INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
    INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
    "${REPOSITORY_ROOT}/ops/bootstrap-plan.sh" apply \
        "${BOOTSTRAP_PLAN}" \
        >"${TEMP_DIR}/bootstrap-apply.out" 2>"${TEMP_DIR}/bootstrap-apply.err"
jq --exit-status '.consumed == true' \
    "${BOOTSTRAP_PLAN}.metadata.json" >/dev/null
test ! -e "${BOOTSTRAP_PLAN}"
grep -Fq 'exact reviewed local bootstrap plan was consumed' \
    "${TEMP_DIR}/bootstrap-apply.out"

printf "Root and plan-policy fixtures passed.\n"
