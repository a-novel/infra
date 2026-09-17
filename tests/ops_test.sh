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
    '  "secrets describe production-json-keys-app-master-key --project=agora-management-test --format=yaml(name,annotations,createTime,versionDestroyTtl)")' \
    '    printf "%s\n" "name: production-json-keys-app-master-key" ;;' \
    '  "secrets versions add production-authentication-postgres-password --project=agora-management-test --data-file=- --quiet --format=value(name.basename())")' \
    '    payload="$(cat)"' \
    '    [ "$payload" = "$FAKE_EXPECTED_SECRET" ]' \
    '    printf "%s" "7" ;;' \
    '  "secrets versions add production-json-keys-app-master-key --project=agora-management-test --data-file=- --quiet --format=value(name.basename())")' \
    '    payload="$(cat)"' \
    '    [ "$payload" = "$FAKE_EXPECTED_SECRET" ]' \
    '    printf "%s" "8" ;;' \
    '  "secrets versions describe 7 --secret=production-authentication-postgres-password --project=agora-management-test --format=value(state)")' \
    '    printf "%s" "ENABLED" ;;' \
    '  "secrets versions describe 7 --secret=production-authentication-postgres-password --project=agora-management-test --format=yaml(name,state,createTime,destroyTime,scheduledDestroyTime)")' \
    '    printf "%s\n" "state: ENABLED" ;;' \
    '  "secrets versions describe 8 --secret=production-json-keys-app-master-key --project=agora-management-test --format=value(state)")' \
    '    printf "%s" "ENABLED" ;;' \
    '  "secrets versions describe 8 --secret=production-json-keys-app-master-key --project=agora-management-test --format=yaml(name,state,createTime,destroyTime,scheduledDestroyTime)")' \
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

printf -v INVALID_MASTER_KEY 'v%063d' 0
set +e
printf '%s\n%s\n' "${INVALID_MASTER_KEY}" "${INVALID_MASTER_KEY}" \
    | PATH="${SECRET_MOCK_BIN}:${PATH}" \
        FAKE_EXPECTED_SECRET="${INVALID_MASTER_KEY}" \
        INFRA_MANAGEMENT_PROJECT_ID=agora-management-test \
        INFRA_WORKLOAD_PROJECT_ID=agora-production-test \
        "${REPOSITORY_ROOT}/ops/add-secret-version.sh" \
            production-json-keys-app-master-key \
            >"${TEMP_DIR}/invalid-master-key.out" 2>"${TEMP_DIR}/invalid-master-key.err"
INVALID_MASTER_KEY_CODE=$?
set -e
assert_equal "${INVALID_MASTER_KEY_CODE}" 65
grep -Fq 'JSON Keys master key requires exactly 64 hexadecimal characters.' \
    "${TEMP_DIR}/invalid-master-key.err"
assert_absent "${TEMP_DIR}/invalid-master-key.err" "${INVALID_MASTER_KEY}"

printf -v MASTER_KEY '%064d' 0
CREATED_MASTER_KEY_VERSION="$(
    printf '%s\n%s\n' "${MASTER_KEY}" "${MASTER_KEY}" \
        | PATH="${SECRET_MOCK_BIN}:${PATH}" \
            FAKE_EXPECTED_SECRET="${MASTER_KEY}" \
            INFRA_MANAGEMENT_PROJECT_ID=agora-management-test \
            INFRA_WORKLOAD_PROJECT_ID=agora-production-test \
            "${REPOSITORY_ROOT}/ops/add-secret-version.sh" \
                production-json-keys-app-master-key \
                2>"${TEMP_DIR}/add-master-key.err"
)"
assert_equal "${CREATED_MASTER_KEY_VERSION}" \
    'Created production-json-keys-app-master-key version 8.'
assert_absent "${TEMP_DIR}/add-master-key.err" "${MASTER_KEY}"
unset INVALID_MASTER_KEY INVALID_MASTER_KEY_CODE MASTER_KEY

set +e
"${REPOSITORY_ROOT}/ops/add-secret-version.sh" \
    production-authentication-postgres-password \
    production-authentication-postgres-password \
    >"${TEMP_DIR}/duplicate-secret.out" 2>"${TEMP_DIR}/duplicate-secret.err"
DUPLICATE_SECRET_CODE=$?
set -e
assert_equal "${DUPLICATE_SECRET_CODE}" 65
grep -Fq 'Refusing duplicate secret ID' "${TEMP_DIR}/duplicate-secret.err"

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
assert_tofu_gate_code assess "${SCRIPT_DIR}/fixtures/plans/safe.json" 0
assert_tofu_gate_code assess "${SCRIPT_DIR}/fixtures/plans/protected.json" 3
assert_tofu_gate_code drift "${SCRIPT_DIR}/fixtures/plans/safe.json" 2
assert_tofu_gate_code drift "${SCRIPT_DIR}/fixtures/plans/protected.json" 2

# Pull-request impact follows both current and previous filenames while
# preserving the smallest production-root set that can change.
jq -n '[{filename: "README.md"}]' >"${TEMP_DIR}/impact-docs.json"
jq -n '[{filename: "environments/production/foundation/main.tf"}]' \
    >"${TEMP_DIR}/impact-foundation.json"
jq -n '[{filename: "deploy/production/images.yaml"}]' \
    >"${TEMP_DIR}/impact-release.json"
jq -n '[{filename: "docs/old.md", previous_filename: "bootstrap/main.tf"}]' \
    >"${TEMP_DIR}/impact-renamed.json"
jq -n '[{filename: "modules/shared/main.tf"}]' \
    >"${TEMP_DIR}/impact-shared.json"

assert_equal "$("${REPOSITORY_ROOT}/ops/resource-deletion-impact.sh" \
    "${TEMP_DIR}/impact-docs.json" | jq --raw-output .required)" false
assert_equal "$("${REPOSITORY_ROOT}/ops/resource-deletion-impact.sh" \
    "${TEMP_DIR}/impact-foundation.json" | jq --compact-output .roots)" '["foundation"]'
assert_equal "$("${REPOSITORY_ROOT}/ops/resource-deletion-impact.sh" \
    "${TEMP_DIR}/impact-release.json" | jq --compact-output .roots)" '["release"]'
assert_equal "$("${REPOSITORY_ROOT}/ops/resource-deletion-impact.sh" \
    "${TEMP_DIR}/impact-renamed.json" | jq --compact-output .roots)" '["bootstrap"]'
assert_equal "$("${REPOSITORY_ROOT}/ops/resource-deletion-impact.sh" \
    "${TEMP_DIR}/impact-shared.json" | jq --compact-output .roots)" \
    '["bootstrap","foundation","release"]'

# The metadata-only merge gate fails closed unless exact protected evidence
# exists, and replays the latest human label decision at evaluation time.
DELETION_GATE_BIN="${TEMP_DIR}/deletion-gate-bin"
mkdir -p "${DELETION_GATE_BIN}"
ln -s "${SCRIPT_DIR}/fixtures/fake-deletion-gate-gh.sh" "${DELETION_GATE_BIN}/gh"
ln -s "${SCRIPT_DIR}/fixtures/fake-tofu.sh" "${DELETION_GATE_BIN}/tofu"
ln -s "${SCRIPT_DIR}/fixtures/fake-gcloud-storage.sh" "${DELETION_GATE_BIN}/gcloud"
DELETION_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DELETION_BASE=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
DELETION_GROUP=cccccccccccccccccccccccccccccccccccccccc

write_deletion_assessment() {
    local approval="$1"
    local first_launch="$2"
    local base="$3"
    local output="$4"
    jq -n \
        --arg head "${DELETION_HEAD}" \
        --arg base "${base}" \
        --argjson approval "${approval}" \
        --argjson first_launch "${first_launch}" '
          {
            schemaVersion: 1,
            repository: "a-novel/infra",
            pullRequest: 93,
            headSha: $head,
            baseSha: $base,
            approvalRequired: $approval,
            firstLaunch: $first_launch
          }
        ' >"${output}"
}

SAFE_ASSESSMENT="${TEMP_DIR}/safe-assessment.json"
DESTRUCTIVE_ASSESSMENT="${TEMP_DIR}/destructive-assessment.json"
MISMATCHED_ASSESSMENT="${TEMP_DIR}/mismatched-assessment.json"
write_deletion_assessment false false "${DELETION_BASE}" "${SAFE_ASSESSMENT}"
write_deletion_assessment true false "${DELETION_BASE}" "${DESTRUCTIVE_ASSESSMENT}"
write_deletion_assessment false false "${DELETION_GROUP}" "${MISMATCHED_ASSESSMENT}"

assert_resource_gate_code() {
    local expected="$1"
    local files="$2"
    local run_mode="$3"
    local label_mode="$4"
    local assessment="$5"
    local event_name="${6:-pull_request}"
    local permission="${7:-admin}"
    local pull_request_head="${8:-${DELETION_HEAD}}"
    local gate_head="${DELETION_HEAD}"
    local check_sha="${DELETION_HEAD}"
    local merge_ref=""
    local code=0
    if [ "${event_name}" = merge_group ]; then
        gate_head=""
        check_sha="${DELETION_GROUP}"
        merge_ref='refs/heads/gh-readonly-queue/master/pr-93-deadbeef'
    fi
    set +e
    PATH="${DELETION_GATE_BIN}:${PATH}" \
        FAKE_GATE_ASSESSMENT_FILE="${assessment}" \
        FAKE_GATE_BASE="${DELETION_BASE}" \
        FAKE_GATE_FILES="${files}" \
        FAKE_GATE_HEAD="${pull_request_head}" \
        FAKE_GATE_LABEL_MODE="${label_mode}" \
        FAKE_GATE_RUN_MODE="${run_mode}" \
        GATE_BASE_SHA="${DELETION_BASE}" \
        FAKE_GATE_PERMISSION="${permission}" \
        GATE_HEAD_SHA="${gate_head}" \
        GATE_MERGE_HEAD_REF="${merge_ref}" \
        GATE_PULL_REQUEST=93 \
        GITHUB_EVENT_NAME="${event_name}" \
        GITHUB_REF=refs/pull/93/merge \
        GITHUB_SHA="${check_sha}" \
        "${REPOSITORY_ROOT}/ops/verify-resource-deletion-gate.sh" a-novel/infra \
        >"${TEMP_DIR}/resource-gate.out" 2>"${TEMP_DIR}/resource-gate.err"
    code=$?
    set -e
    assert_equal "${code}" "${expected}"
}

assert_resource_gate_code 0 docs no-run missing "${SAFE_ASSESSMENT}"
assert_resource_gate_code 70 failed no-run missing "${SAFE_ASSESSMENT}"
assert_resource_gate_code 77 image no-run missing "${SAFE_ASSESSMENT}"
assert_resource_gate_code 77 image failed missing "${SAFE_ASSESSMENT}"
assert_resource_gate_code 0 image success missing "${SAFE_ASSESSMENT}"
assert_resource_gate_code 77 image success missing "${DESTRUCTIVE_ASSESSMENT}"
assert_resource_gate_code 0 image success approved "${DESTRUCTIVE_ASSESSMENT}"
assert_resource_gate_code 77 image success bot "${DESTRUCTIVE_ASSESSMENT}"
assert_resource_gate_code 77 image success approved "${MISMATCHED_ASSESSMENT}"
assert_resource_gate_code 77 image success untrusted "${DESTRUCTIVE_ASSESSMENT}" pull_request read
assert_resource_gate_code 77 image success missing "${SAFE_ASSESSMENT}" pull_request admin dddddddddddddddddddddddddddddddddddddddd
assert_resource_gate_code 0 image success missing "${SAFE_ASSESSMENT}" merge_group

# The trusted dispatcher check accepts human maintainers and fork candidates,
# while a first release with no converged input record always needs approval.
RESOLVED_FORK="$(
    PATH="${DELETION_GATE_BIN}:${PATH}" \
        FAKE_GATE_BASE="${DELETION_BASE}" \
        FAKE_GATE_HEAD="${DELETION_HEAD}" \
        FAKE_GATE_HEAD_REPOSITORY=contributor/infra \
        GITHUB_ACTOR=maintainer \
        GITHUB_REF=refs/heads/master \
        GITHUB_SHA="${DELETION_BASE}" \
        "${REPOSITORY_ROOT}/ops/resolve-resource-deletion-assessment.sh" \
            a-novel/infra 93 "${DELETION_HEAD}" "${DELETION_BASE}"
)"
assert_equal "${RESOLVED_FORK}" contributor/infra

set +e
PATH="${DELETION_GATE_BIN}:${PATH}" \
    FAKE_GATE_ACTOR_TYPE=Bot \
    FAKE_GATE_BASE="${DELETION_BASE}" \
    FAKE_GATE_HEAD="${DELETION_HEAD}" \
    GITHUB_ACTOR=renovate \
    GITHUB_REF=refs/heads/master \
    GITHUB_SHA="${DELETION_BASE}" \
    "${REPOSITORY_ROOT}/ops/resolve-resource-deletion-assessment.sh" \
        a-novel/infra 93 "${DELETION_HEAD}" "${DELETION_BASE}" \
        >/dev/null 2>&1
BOT_ASSESSMENT_CODE=$?
set -e
assert_equal "${BOT_ASSESSMENT_CODE}" 77

CANDIDATE_REPOSITORY="${TEMP_DIR}/candidate-infra"
mkdir -p "${CANDIDATE_REPOSITORY}" "${TEMP_DIR}/empty-gcs"
git -C "${CANDIDATE_REPOSITORY}" init -q -b master
git -C "${CANDIDATE_REPOSITORY}" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -q --allow-empty -m fixture
CANDIDATE_HEAD="$(git -C "${CANDIDATE_REPOSITORY}" rev-parse HEAD)"
FIRST_LAUNCH_ASSESSMENT="${TEMP_DIR}/first-launch-assessment.json"
PATH="${DELETION_GATE_BIN}:${PATH}" \
    FAKE_GATE_BASE="${DELETION_BASE}" \
    FAKE_GATE_FILES=image \
    FAKE_GATE_HEAD="${CANDIDATE_HEAD}" \
    FAKE_GCS_ROOT="${TEMP_DIR}/empty-gcs" \
    "${REPOSITORY_ROOT}/ops/prepare-resource-deletion-assessment.sh" \
        a-novel/infra 93 "${CANDIDATE_HEAD}" "${DELETION_BASE}" \
        "${CANDIDATE_REPOSITORY}" agora-state-test \
        "${FIRST_LAUNCH_ASSESSMENT}"
jq --exit-status '
  .approvalRequired == true and
  .firstLaunch == true
' "${FIRST_LAUNCH_ASSESSMENT}" >/dev/null


# The metadata-only path shares first-launch policy and never needs a candidate checkout or provider.
IMAGE_ONLY_BIN="${TEMP_DIR}/image-only-bin"
mkdir -p "${IMAGE_ONLY_BIN}"
ln -s "${SCRIPT_DIR}/fixtures/fake-deletion-gate-gh.sh" "${IMAGE_ONLY_BIN}/gh"
ln -s "${SCRIPT_DIR}/fixtures/fake-gcloud-storage.sh" "${IMAGE_ONLY_BIN}/gcloud"
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/bash' '[ "$*" = "assess-images verify" ] || exit 99' \
    'exit "${FAKE_INFRA_VERIFY_CODE:-0}"' >"${IMAGE_ONLY_BIN}/infra"
printf '%s\n' '#!/bin/bash' 'exit 97' >"${IMAGE_ONLY_BIN}/tofu"
chmod 0700 "${IMAGE_ONLY_BIN}/infra" "${IMAGE_ONLY_BIN}/tofu"

assert_image_only_assessment() {
    local expected_code="$1"
    local output="${TEMP_DIR}/automatic-assessment.json"
    rm -f -- "${output}"
    local code=0
    PATH="${IMAGE_ONLY_BIN}:${PATH}" \
        FAKE_GATE_BASE="${DELETION_BASE}" FAKE_GATE_HEAD="${DELETION_HEAD}" \
        FAKE_GCS_ROOT="${TEMP_DIR}/image-only-gcs" \
        "${REPOSITORY_ROOT}/ops/prepare-resource-deletion-assessment.sh" \
            a-novel/infra 93 "${DELETION_HEAD}" "${DELETION_BASE}" --image-only \
            agora-state-test "${output}" >"${TEMP_DIR}/automatic.out" 2>"${TEMP_DIR}/automatic.err" || code=$?
    assert_equal "${code}" "${expected_code}"
    if [ "${code}" -ne 0 ]; then
        [ ! -e "${output}" ]
    fi
}
FAKE_GATE_FILES=image assert_image_only_assessment 0
jq -e '.firstLaunch and .approvalRequired' "${TEMP_DIR}/automatic-assessment.json" >/dev/null
IMAGE_CONFIG_DIR="${TEMP_DIR}/image-only-gcs/agora-state-test/release/config"
mkdir -p "${IMAGE_CONFIG_DIR}"
printf '%s\n' '{"application_release":null}' >"${IMAGE_CONFIG_DIR}/00000000000000000001-00001.tfvars.json"
FAKE_GATE_FILES=image assert_image_only_assessment 0
jq -e '.firstLaunch and .approvalRequired' "${TEMP_DIR}/automatic-assessment.json" >/dev/null
printf '%s\n' '{"application_release":{}}' >"${IMAGE_CONFIG_DIR}/00000000000000000001-00001.tfvars.json"
FAKE_GATE_FILES=image assert_image_only_assessment 0
jq -e '(.firstLaunch | not) and (.approvalRequired | not)' "${TEMP_DIR}/automatic-assessment.json" >/dev/null
FAKE_GATE_FILES=foundation assert_image_only_assessment 77
FAKE_GATE_FILES=image FAKE_GCS_LIST_FAILURE=true assert_image_only_assessment 70
FAKE_GATE_FILES=image FAKE_INFRA_VERIFY_CODE=77 assert_image_only_assessment 77

mkdir -p "${CANDIDATE_REPOSITORY}/environments/production/foundation"
printf '%s\n' '{}' \
    >"${CANDIDATE_REPOSITORY}/environments/production/foundation/main.tf"
git -C "${CANDIDATE_REPOSITORY}" add environments/production/foundation/main.tf
git -C "${CANDIDATE_REPOSITORY}" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -q -m foundation
CANDIDATE_HEAD="$(git -C "${CANDIDATE_REPOSITORY}" rev-parse HEAD)"
printf '%s\n' '{}' >"${TEMP_DIR}/foundation-current.json"
PATH="${DELETION_GATE_BIN}:${PATH}" \
    FAKE_GCS_ROOT="${TEMP_DIR}/empty-gcs" \
    "${REPOSITORY_ROOT}/ops/config-custody.sh" publish \
        agora-state-test foundation "${TEMP_DIR}/foundation-current.json" 1 1 \
        >/dev/null
DESTRUCTIVE_PLAN_ASSESSMENT="${TEMP_DIR}/destructive-plan-assessment.json"
PATH="${DELETION_GATE_BIN}:${PATH}" \
    FAKE_GATE_BASE="${DELETION_BASE}" \
    FAKE_GATE_FILES=foundation \
    FAKE_GATE_HEAD="${CANDIDATE_HEAD}" \
    FAKE_GCS_ROOT="${TEMP_DIR}/empty-gcs" \
    FAKE_TOFU_PLAN_CODE=2 \
    FAKE_TOFU_PLAN_JSON="${SCRIPT_DIR}/fixtures/plans/protected.json" \
    "${REPOSITORY_ROOT}/ops/prepare-resource-deletion-assessment.sh" \
        a-novel/infra 93 "${CANDIDATE_HEAD}" "${DELETION_BASE}" \
        "${CANDIDATE_REPOSITORY}" agora-state-test \
        "${DESTRUCTIVE_PLAN_ASSESSMENT}" \
        >"${TEMP_DIR}/destructive-assessment.out" \
        2>"${TEMP_DIR}/destructive-assessment.err"
jq --exit-status '
  .approvalRequired == true and
  .firstLaunch == false
' "${DESTRUCTIVE_PLAN_ASSESSMENT}" >/dev/null
assert_absent "${TEMP_DIR}/destructive-assessment.out" google_compute_disk
assert_absent "${TEMP_DIR}/destructive-assessment.err" google_compute_disk
assert_absent "${TEMP_DIR}/destructive-assessment.out" fixture-project-id
assert_absent "${TEMP_DIR}/destructive-assessment.err" fixture-project-id

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
    FAKE_TOFU_PLAN_JSON="${SCRIPT_DIR}/fixtures/plans/safe.json" \
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
PRE_MERGE_TIMELINE='[[{"id":1,"event":"labeled","created_at":"2026-08-25T11:00:00Z","label":{"name":"allow-resource-deletion"},"actor":{"login":"maintainer","type":"User"}},{"id":2,"event":"merged","created_at":"2026-08-25T12:00:00Z"}]]'
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
    '[[{"id":1,"event":"merged","created_at":"2026-08-25T12:00:00Z"},{"id":2,"event":"labeled","created_at":"2026-08-25T12:01:00Z","label":{"name":"allow-resource-deletion"},"actor":{"login":"maintainer","type":"User"}}]]' \
    write
assert_deletion_gate_rejects \
    '[[{"id":1,"event":"labeled","created_at":"2026-08-25T11:00:00Z","label":{"name":"allow-resource-deletion"},"actor":{"login":"maintainer","type":"User"}},{"id":2,"event":"unlabeled","created_at":"2026-08-25T11:30:00Z","label":{"name":"allow-resource-deletion"},"actor":{"login":"maintainer","type":"User"}},{"id":3,"event":"merged","created_at":"2026-08-25T12:00:00Z"}]]' \
    write
assert_deletion_gate_rejects "${PRE_MERGE_TIMELINE}" triage
assert_deletion_gate_rejects "$(jq '.[0][0].actor.type = "Bot"' <<<"${PRE_MERGE_TIMELINE}")" write
assert_deletion_gate_rejects "$(jq '.[0][0].performed_via_github_app = {id: 123}' <<<"${PRE_MERGE_TIMELINE}")" write

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

# Cloud Quotas may omit the optional justification and default-false
# reconciling fields. Omission is accepted, while a pending preference fails.
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
      {service:"run.googleapis.com", dimensions:{region:"europe-west1"}, quotaConfig:{preferredValue:"8000", grantedValue:"8000"}},
      {service:"run.googleapis.com", dimensions:{region:"europe-west1"}, quotaConfig:{preferredValue:"17179869184", grantedValue:"17179869184"}},
      {service:"compute.googleapis.com", dimensions:{region:"europe-west1"}, reconciling:$pending, quotaConfig:{preferredValue:"4", grantedValue:"4"}}
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
  .cloud.secretVersions = [range(1; 8) | ["production-test-\(.)", .]]
' "${TEMP_DIR}/preflight.json" >"${TEMP_DIR}/preflight-deploy.json"

: >"${PREFLIGHT_GCLOUD_LOG}"
PATH="${PREFLIGHT_MOCK_BIN}:${PATH}" \
    PREFLIGHT_GCLOUD_LOG="${PREFLIGHT_GCLOUD_LOG}" \
    "${REPOSITORY_ROOT}/ops/preflight-release.sh" \
    "${TEMP_DIR}/preflight-deploy.json" >/dev/null
assert_equal "$(grep -Fxc 'secrets versions describe' "${PREFLIGHT_GCLOUD_LOG}")" 7
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
    'if [[ "$*" == *"compute disks describe"* ]]; then printf "1002\\n"; fi' \
    'if [[ "$*" == *"instance-groups managed describe"* ]]; then' \
    '    if [[ "${METADATA_DESCRIBE_ERROR:-false}" == "true" ]]; then' \
    '        printf "mock metadata describe denied\\n" >&2' \
    '        exit 1' \
    '    elif [[ "${INVALID_METADATA_SHAPE:-false}" == "true" ]]; then' \
    "        printf '%s\\n' '{\"allInstancesConfig\":{\"properties\":{\"metadata\":{\"unexpected-key\":\"value\"}}}}'" \
    '    elif [[ -n "${RECOVERY_REVISION:-}" ]]; then' \
    '        recovery_digest="$(printf "a%.0s" {1..64})"' \
    '        jq -nc --arg revision "$RECOVERY_REVISION" --arg image "europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/database@sha256:$recovery_digest" '"'"'{allInstancesConfig:{properties:{metadata:{"agora-database-release-revision":$revision,"agora-json-keys-database-image":$image,"agora-json-keys-postgres-password-version":"7","agora-json-keys-postgres-backup-password-version":"13"}}}}'"'"'' \
    '    else' \
    '        if [[ "${INITIAL_DATABASE_RELEASE:-false}" == "true" ]]; then current_revision=""; else current_revision="ffffffffffffffffffffffffffffffffffffffff"; fi' \
    '        jq -nc --arg revision "$current_revision" '"'"'{allInstancesConfig:{properties:{metadata:{"agora-database-release-revision":$revision,"agora-json-keys-database-image":"","agora-json-keys-postgres-password-version":"0","agora-json-keys-postgres-backup-password-version":"0"}}}}'"'"'' \
    '    fi' \
    'fi' \
    'if [[ "$*" == *"instance-groups managed list-instances"* ]]; then' \
    '    printf "agora-database-json-keys-test\n"' \
    'fi' \
    'if [[ "$*" == *"instances get-guest-attributes"* ]]; then' \
    '    if [[ "${READINESS_PERMISSION_ERROR:-false}" == "true" ]]; then' \
    '        printf "PERMISSION_DENIED: compute.instances.getGuestAttributes\n" >&2' \
    '        exit 1' \
    '    fi' \
    '    if [[ "${READINESS_ABSENT:-false}" == "true" ]]; then' \
    '        printf "ERROR: Guest Attribute was not found.\n" >&2' \
    '        exit 1' \
    '    fi' \
    '    guest_call_count="$(grep -Fxc get-guest-attributes "${GCLOUD_ARGUMENT_LOG}")"' \
    '    if [[ "${guest_call_count}" == "1" ]]; then' \
    '        guest_status="healthy:ffffffffffffffffffffffffffffffffffffffff:11111111-1111-1111-1111-111111111111"' \
    '    elif [[ "${READINESS_FAILURE:-false}" == "true" ]]; then' \
    '        guest_status="failed:0123456789abcdef0123456789abcdef01234567:22222222-2222-2222-2222-222222222222"' \
    '    elif [[ "${READINESS_EXPECTED:-}" == "none" ]]; then' \
    '        guest_status="idle:none:22222222-2222-2222-2222-222222222222"' \
    '    else' \
    '        guest_status="healthy:0123456789abcdef0123456789abcdef01234567:22222222-2222-2222-2222-222222222222"' \
    '    fi' \
    '    if [[ "$*" == *"--format=json"* ]]; then' \
    '        printf "[{\"namespace\":\"agora\",\"key\":\"database-release\",\"value\":\"%s\"}]\n" "${guest_status}"' \
    '    elif [[ "$*" == *"--format=value(value)"* ]]; then' \
    '        printf "%s\n" "${guest_status}"' \
    '    else' \
    '        printf "mock guest attribute format is unsupported\n" >&2' \
    '        exit 1' \
    '    fi' \
    'fi' \
    'if [[ "$*" == *"compute snapshots list"* ]]; then' \
    '    if [[ -n "${SNAPSHOT_AGE_HOURS:-}" ]]; then snapshot_time="$(date -u --date="${SNAPSHOT_AGE_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ)"; else snapshot_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi' \
    '    if [[ "${MANUAL_SNAPSHOT:-false}" == "true" ]]; then snapshot_auto_created=false; else snapshot_auto_created=true; fi' \
    '    printf "[{\"name\":\"agora-scheduled-snapshot\",\"autoCreated\":%s,\"sourceDisk\":\"https://www.googleapis.com/compute/v1/projects/agora-production-test/zones/europe-west1-c/disks/agora-data-json-keys\",\"sourceDiskId\":\"1002\",\"status\":\"READY\",\"creationTimestamp\":\"%s\",\"storageLocations\":[\"europe-west1\"],\"labels\":{\"application\":\"agora\",\"environment\":\"production\",\"managed-by\":\"opentofu\",\"plane\":\"workload\",\"role\":\"database-snapshot\",\"component\":\"json-keys\"}}]\n" "${snapshot_auto_created}" "${snapshot_time}"' \
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
    json-keys 1002 \
    0123456789abcdef0123456789abcdef01234567 \
    "${JSON_KEYS_IMAGE}" \
    7 \
    13 \
    >"${TEMP_DIR}/database-release.out"

assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "12"
grep -Fqx 'describe' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'snapshots' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'list' "${GCLOUD_ARGUMENT_LOG}"
assert_equal "$(grep -Fc 'execute' "${GCLOUD_ARGUMENT_LOG}")" "1"
grep -Fqx 'agora-postgres-backup-json-keys' "${GCLOUD_ARGUMENT_LOG}"
if grep -Fqx 'agora-postgres-backup-authentication' "${GCLOUD_ARGUMENT_LOG}"; then
    printf 'A JSON Keys release must not back up Authentication.\n' >&2
    exit 1
fi
grep -Fqx -- '--wait' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'all-instances-config' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'update-instances' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'wait-until' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--stable' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--timeout=600' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--format=json' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--all-instances' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--minimal-action=restart' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--most-disruptive-allowed-action=restart' "${GCLOUD_ARGUMENT_LOG}"
assert_equal "$(grep -Fxc 'get-guest-attributes' "${GCLOUD_ARGUMENT_LOG}")" "2"
grep -Fq 'Database host reported healthy release 0123456789abcdef0123456789abcdef01234567.' \
    "${TEMP_DIR}/database-release.out"
grep -Fqx -- "--metadata=agora-database-release-revision=0123456789abcdef0123456789abcdef01234567,agora-json-keys-database-image=${JSON_KEYS_IMAGE},agora-json-keys-postgres-password-version=7,agora-json-keys-postgres-backup-password-version=13" "${GCLOUD_ARGUMENT_LOG}"

# A new boot-specific failure stops the database stage before candidate
# services can start against an unavailable PostgreSQL listener.
: >"${GCLOUD_ARGUMENT_LOG}"
set +e
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    READINESS_FAILURE=true \
    "${REPOSITORY_ROOT}/ops/deploy-database-release.sh" \
    agora-production-test \
    europe-west1-c \
    json-keys 1002 \
    0123456789abcdef0123456789abcdef01234567 \
    "${JSON_KEYS_IMAGE}" \
    7 \
    13 \
    >"${TEMP_DIR}/failed-database-readiness.out" \
    2>"${TEMP_DIR}/failed-database-readiness.err"
FAILED_DATABASE_READINESS_CODE=$?
set -e
assert_equal "${FAILED_DATABASE_READINESS_CODE}" 70
grep -Fq 'reported failed startup status' "${TEMP_DIR}/failed-database-readiness.err"
grep -Fq 'did not report a healthy release' "${TEMP_DIR}/failed-database-readiness.err"

# A missing status before the first instrumented boot is valid, but any real
# provider or IAM failure remains distinct and fails closed.
: >"${GCLOUD_ARGUMENT_LOG}"
READINESS_ABSENT=true PATH="${MOCK_BIN}:${PATH}" \
    GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    "${REPOSITORY_ROOT}/ops/database-host-readiness.sh" current \
    agora-production-test europe-west1-c json-keys \
    >"${TEMP_DIR}/absent-database-readiness.out"
assert_equal "$(cat "${TEMP_DIR}/absent-database-readiness.out")" absent

: >"${GCLOUD_ARGUMENT_LOG}"
set +e
READINESS_PERMISSION_ERROR=true PATH="${MOCK_BIN}:${PATH}" \
    GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    "${REPOSITORY_ROOT}/ops/deploy-database-release.sh" \
    agora-production-test \
    europe-west1-c \
    json-keys 1002 \
    0123456789abcdef0123456789abcdef01234567 \
    "${JSON_KEYS_IMAGE}" \
    7 \
    13 \
    >"${TEMP_DIR}/denied-database-readiness.out" \
    2>"${TEMP_DIR}/denied-database-readiness.err"
DENIED_DATABASE_READINESS_CODE=$?
set -e
assert_equal "${DENIED_DATABASE_READINESS_CODE}" 70
grep -Fq 'PERMISSION_DENIED' "${TEMP_DIR}/denied-database-readiness.err"
if grep -Eq '^(all-instances-config|update-instances)$' "${GCLOUD_ARGUMENT_LOG}"; then
    printf 'Unreadable database readiness must fail before metadata mutation.\n' >&2
    exit 1
fi

# Compensation also waits for a new boot to report the prior state. A null
# receipt must result in an explicit idle signal rather than MIG stability.
printf 'null\n' >"${TEMP_DIR}/empty-database-receipt.json"
: >"${GCLOUD_ARGUMENT_LOG}"
READINESS_EXPECTED=none PATH="${MOCK_BIN}:${PATH}" \
    GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    "${REPOSITORY_ROOT}/ops/restore-database-release.sh" \
    agora-production-test \
    europe-west1-c \
    json-keys 1002 \
    "${TEMP_DIR}/empty-database-receipt.json" \
    >"${TEMP_DIR}/database-rollback.out"
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "8"
grep -Fq 'Database host reported the idle rollback state.' \
    "${TEMP_DIR}/database-rollback.out"

# An interrupted first launch is recoverable only while no receipt exists and
# the complete live database metadata map identifies that failed revision.
FIRST_LAUNCH_RECOVERY_DIR="${TEMP_DIR}/first-launch-recovery"
FIRST_LAUNCH_RECOVERY_LOG="${TEMP_DIR}/first-launch-recovery.log"
mkdir -p "${FIRST_LAUNCH_RECOVERY_DIR}"
ln -s "${REPOSITORY_ROOT}/ops/recover-first-launch.sh" \
    "${FIRST_LAUNCH_RECOVERY_DIR}/recover-first-launch.sh"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'if [ "$#" -ne 3 ] || [ "$1" != latest ] || [ "$2" != agora-receipts-test ]; then exit 64; fi' \
    'printf "receipt\n" >>"${FIRST_LAUNCH_RECOVERY_LOG}"' \
    'if [ "${RECOVERY_RECEIPT_PRESENT:-false}" = true ]; then printf "{}\\n" >"$3"; exit 0; fi' \
    'exit 4' \
    >"${FIRST_LAUNCH_RECOVERY_DIR}/receipt-custody.sh"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'if [ "$#" -ne 5 ] || [ "$1" != agora-production-test ] || [ "$2" != europe-west1-c ]; then exit 64; fi' \
    'grep -Fxq null "$5"' \
    'printf "restore\n" >>"${FIRST_LAUNCH_RECOVERY_LOG}"' \
    >"${FIRST_LAUNCH_RECOVERY_DIR}/restore-database-release.sh"
chmod 0700 \
    "${FIRST_LAUNCH_RECOVERY_DIR}/receipt-custody.sh" \
    "${FIRST_LAUNCH_RECOVERY_DIR}/restore-database-release.sh"

FAILED_FIRST_LAUNCH_REVISION="$(printf 'd%.0s' {1..40})"
: >"${FIRST_LAUNCH_RECOVERY_LOG}"
: >"${GCLOUD_ARGUMENT_LOG}"
FIRST_LAUNCH_RECOVERY_OUTPUT="$(
    PATH="${MOCK_BIN}:${PATH}" \
        GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
        FIRST_LAUNCH_RECOVERY_LOG="${FIRST_LAUNCH_RECOVERY_LOG}" \
        RECOVERY_REVISION="${FAILED_FIRST_LAUNCH_REVISION}" \
        "${FIRST_LAUNCH_RECOVERY_DIR}/recover-first-launch.sh" \
            agora-receipts-test agora-production-test europe-west1-c json-keys 1002 \
            "${FAILED_FIRST_LAUNCH_REVISION}"
)"
assert_equal "${FIRST_LAUNCH_RECOVERY_OUTPUT}" \
    'Interrupted first-launch database metadata cleared.'
assert_equal "$(paste -sd, "${FIRST_LAUNCH_RECOVERY_LOG}")" 'receipt,restore'
assert_equal "$(grep -Fxc CALL "${GCLOUD_ARGUMENT_LOG}")" 2

: >"${FIRST_LAUNCH_RECOVERY_LOG}"
set +e
PATH="${MOCK_BIN}:${PATH}" \
    GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    FIRST_LAUNCH_RECOVERY_LOG="${FIRST_LAUNCH_RECOVERY_LOG}" \
    RECOVERY_REVISION="$(printf 'e%.0s' {1..40})" \
    "${FIRST_LAUNCH_RECOVERY_DIR}/recover-first-launch.sh" \
        agora-receipts-test agora-production-test europe-west1-c json-keys 1002 \
        "${FAILED_FIRST_LAUNCH_REVISION}" \
        >"${TEMP_DIR}/first-launch-mismatch.out" \
        2>"${TEMP_DIR}/first-launch-mismatch.err"
FIRST_LAUNCH_MISMATCH_CODE=$?
set -e
assert_equal "${FIRST_LAUNCH_MISMATCH_CODE}" 70
assert_equal "$(paste -sd, "${FIRST_LAUNCH_RECOVERY_LOG}")" receipt
grep -Fq 'not the exact interrupted first-launch state' \
    "${TEMP_DIR}/first-launch-mismatch.err"

: >"${FIRST_LAUNCH_RECOVERY_LOG}"
: >"${GCLOUD_ARGUMENT_LOG}"
set +e
PATH="${MOCK_BIN}:${PATH}" \
    GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    FIRST_LAUNCH_RECOVERY_LOG="${FIRST_LAUNCH_RECOVERY_LOG}" \
    RECOVERY_RECEIPT_PRESENT=true \
    "${FIRST_LAUNCH_RECOVERY_DIR}/recover-first-launch.sh" \
        agora-receipts-test agora-production-test europe-west1-c json-keys 1002 \
        "${FAILED_FIRST_LAUNCH_REVISION}" \
        >"${TEMP_DIR}/first-launch-receipt.out" \
        2>"${TEMP_DIR}/first-launch-receipt.err"
FIRST_LAUNCH_RECEIPT_CODE=$?
set -e
assert_equal "${FIRST_LAUNCH_RECEIPT_CODE}" 70
assert_equal "$(paste -sd, "${FIRST_LAUNCH_RECOVERY_LOG}")" receipt
grep -Fq 'successful release receipt exists' \
    "${TEMP_DIR}/first-launch-receipt.err"
if [ -s "${GCLOUD_ARGUMENT_LOG}" ]; then
    printf 'First-launch recovery inspected live state despite an existing receipt.\n' >&2
    exit 1
fi

# The first release has no source cluster to dump. A 25-hour daily snapshot is
# accepted, and the gate returns before attempting a nonexistent backup job.
: >"${GCLOUD_ARGUMENT_LOG}"
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    INITIAL_DATABASE_RELEASE=true \
    SNAPSHOT_AGE_HOURS=25 \
    "${REPOSITORY_ROOT}/ops/prepare-database-change.sh" \
    agora-production-test \
    europe-west1-c \
    json-keys 1002 \
    0123456789abcdef0123456789abcdef01234567 \
    >"${TEMP_DIR}/initial-database-gate.out"
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "3"
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
    json-keys 1002 \
    0123456789abcdef0123456789abcdef01234567 \
    "${INITIAL_DATABASE_PROOF}" \
    >"${TEMP_DIR}/initial-database-proof.out"
jq --exit-status '
  keys == ["checkedAt", "currentMetadataSha256", "dataDiskId", "project", "revision", "service", "zone"] and
  (.currentMetadataSha256 | test("^[a-f0-9]{64}$"))
' "${INITIAL_DATABASE_PROOF}" >/dev/null

DRIVER_MOCK_BIN="${TEMP_DIR}/driver-bin"
DRIVER_RELEASE_DIRECTORY="${TEMP_DIR}/driver-release"
mkdir -p "${DRIVER_MOCK_BIN}" "${DRIVER_RELEASE_DIRECTORY}"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'if [ "$1 $2 $3" = "secrets versions describe" ]; then' \
    '    printf "ENABLED\n"' \
    'elif [ "$1 $2 $3" = "quotas preferences list" ]; then' \
    '    printf "%s\n" "[{\"service\":\"run.googleapis.com\",\"dimensions\":{\"region\":\"europe-west1\"},\"quotaConfig\":{\"preferredValue\":\"8000\",\"grantedValue\":\"8000\"}},{\"service\":\"run.googleapis.com\",\"dimensions\":{\"region\":\"europe-west1\"},\"quotaConfig\":{\"preferredValue\":\"17179869184\",\"grantedValue\":\"17179869184\"}},{\"service\":\"compute.googleapis.com\",\"dimensions\":{\"region\":\"europe-west1\"},\"quotaConfig\":{\"preferredValue\":\"4\",\"grantedValue\":\"4\"}}]"' \
    'else' \
    '    exec "${DATABASE_GCLOUD}" "$@"' \
    'fi' \
    >"${DRIVER_MOCK_BIN}/gcloud"
chmod 0700 "${DRIVER_MOCK_BIN}/gcloud"

DRIVER_COMMIT=0123456789abcdef0123456789abcdef01234567
jq -n --arg commit "${DRIVER_COMMIT}" '
  {
    releaseRevision: "",
    jsonKeysImage: "",
    authenticationImage: "",
    jsonKeysPasswordVersion: 0,
    authenticationPasswordVersion: 0,
    jsonKeysBackupPasswordVersion: 0,
    authenticationBackupPasswordVersion: 0
  } as $database |
  {
    schemaVersion: 1,
    services: ["json_keys"],
    action: "deploy",
    commit: $commit,
    runId: "123",
    runAttempt: 1,
    cloud: {
      managementProjectId: "agora-management-test",
      workloadProjectId: "agora-production-test",
      region: "europe-west1",
      databaseZone: "europe-west1-c",
      databaseHosts: {json_keys: {private_ip: "10.20.0.3", data_disk_id: "1002"}},
      secretVersions: [range(1; 8) | ["production-test-\(.)", 1]],
      quotaExpectations: {
        cloud_run_cpu_millicpu: 8000,
        cloud_run_memory_bytes: 17179869184,
        compute_cpu: 4
      }
    },
    currentDatabase: $database,
    previousDatabase: $database
  }
' >"${DRIVER_RELEASE_DIRECTORY}/release.json"

: >"${GCLOUD_ARGUMENT_LOG}"
PATH="${DRIVER_MOCK_BIN}:${PATH}" \
    DATABASE_GCLOUD="${MOCK_BIN}/gcloud" \
    GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    INITIAL_DATABASE_RELEASE=true \
    RELEASE_DIRECTORY="${DRIVER_RELEASE_DIRECTORY}" \
    STATE_BUCKET=agora-state-test \
    RECEIPT_BUCKET=agora-receipts-test \
    GITHUB_SHA="${DRIVER_COMMIT}" \
    GITHUB_RUN_ID=123 \
    GITHUB_RUN_ATTEMPT=1 \
    "${REPOSITORY_ROOT}/ops/google-release-driver.sh" preflight \
    >"${TEMP_DIR}/driver-preflight.out"
test -s "${DRIVER_RELEASE_DIRECTORY}/database-change-json_keys.json"
test -s "${DRIVER_RELEASE_DIRECTORY}/operations.json"

: >"${GCLOUD_ARGUMENT_LOG}"
set +e
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    INITIAL_DATABASE_RELEASE=true \
    "${REPOSITORY_ROOT}/ops/prepare-database-change.sh" \
    agora-production-test \
    europe-west1-c \
    json-keys 1002 \
    0123456789abcdef0123456789abcdef01234567 \
    "${TEMP_DIR}/rejected-database-proof.json" \
    ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
    >/dev/null 2>&1
DATABASE_RECEIPT_DRIFT_CODE=$?
set -e
assert_equal "${DATABASE_RECEIPT_DRIFT_CODE}" 70
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" 2
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
    json-keys 1002 \
    abbreviated \
    "${JSON_KEYS_IMAGE}" \
    7 \
    13 \
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
    json-keys 1002 \
    0123456789abcdef0123456789abcdef01234567 \
    "${JSON_KEYS_IMAGE}" \
    7 \
    13 \
    >"${TEMP_DIR}/invalid-database-metadata.out" \
    2>"${TEMP_DIR}/invalid-database-metadata.err"
INVALID_DATABASE_METADATA_CODE=$?
set -e
assert_equal "${INVALID_DATABASE_METADATA_CODE}" "70"
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "2"
grep -Fq '"missing":' "${TEMP_DIR}/invalid-database-metadata.err"
grep -Fq '"unexpected":["unexpected-key"]' "${TEMP_DIR}/invalid-database-metadata.err"
if grep -Fq '"value"' "${TEMP_DIR}/invalid-database-metadata.err"; then
    printf "Database metadata diagnostics must not print metadata values.\n" >&2
    exit 1
fi
if grep -Eq '^(all-instances-config|update-instances)$' "${GCLOUD_ARGUMENT_LOG}"; then
    printf "Unexpected database metadata must fail before a mutation.\n" >&2
    exit 1
fi

# A retrieval failure keeps the original Cloud CLI diagnostic distinct from a
# valid response whose metadata keys violate the release contract.
: >"${GCLOUD_ARGUMENT_LOG}"
set +e
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    METADATA_DESCRIBE_ERROR=true \
    "${REPOSITORY_ROOT}/ops/prepare-database-change.sh" \
    agora-production-test \
    europe-west1-c \
    json-keys 1002 \
    0123456789abcdef0123456789abcdef01234567 \
    >"${TEMP_DIR}/inaccessible-database-metadata.out" \
    2>"${TEMP_DIR}/inaccessible-database-metadata.err"
INACCESSIBLE_DATABASE_METADATA_CODE=$?
set -e
assert_equal "${INACCESSIBLE_DATABASE_METADATA_CODE}" "70"
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "2"
grep -Fq 'mock metadata describe denied' "${TEMP_DIR}/inaccessible-database-metadata.err"
grep -Fq 'Database release metadata could not be inspected.' \
    "${TEMP_DIR}/inaccessible-database-metadata.err"
if grep -Fq 'shape differs' "${TEMP_DIR}/inaccessible-database-metadata.err"; then
    printf "A metadata retrieval failure must not be reported as a shape mismatch.\n" >&2
    exit 1
fi

# A database change is blocked outside the 26-hour daily snapshot window,
# before a logical backup or metadata mutation can begin.
: >"${GCLOUD_ARGUMENT_LOG}"
set +e
PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    SNAPSHOT_AGE_HOURS=27 \
    "${REPOSITORY_ROOT}/ops/deploy-database-release.sh" \
    agora-production-test \
    europe-west1-c \
    json-keys 1002 \
    0123456789abcdef0123456789abcdef01234567 \
    "${JSON_KEYS_IMAGE}" \
    7 \
    13 \
    >"${TEMP_DIR}/stale-database-snapshot.out" \
    2>"${TEMP_DIR}/stale-database-snapshot.err"
STALE_DATABASE_SNAPSHOT_CODE=$?
set -e
assert_equal "${STALE_DATABASE_SNAPSHOT_CODE}" "70"
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "3"
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
    json-keys 1002 \
    0123456789abcdef0123456789abcdef01234567 \
    >"${TEMP_DIR}/manual-database-snapshot.out" \
    2>"${TEMP_DIR}/manual-database-snapshot.err"
MANUAL_DATABASE_SNAPSHOT_CODE=$?
set -e
assert_equal "${MANUAL_DATABASE_SNAPSHOT_CODE}" "70"
assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "3"
if grep -Eq '^(execute|all-instances-config|update-instances)$' "${GCLOUD_ARGUMENT_LOG}"; then
    printf "A manual snapshot must fail before backup or database mutation.\n" >&2
    exit 1
fi

if ! grep -Fq ".currentDatabase as \$database" \
    "${REPOSITORY_ROOT}/ops/google-release-driver.sh" ||
    grep -Fq ".previousDatabase as \$database" \
        "${REPOSITORY_ROOT}/ops/google-release-driver.sh"; then
    printf 'Release preflight must compare live metadata with the current receipt, not the rollback target.\n' >&2
    exit 1
fi

# Only an explicit pre-execution tag authorization denial may retry.
# Application failures stop after one Cloud Run execution.
RELEASE_JOB_MOCK_BIN="${TEMP_DIR}/release-job-bin"
RELEASE_JOB_DIRECTORY="${TEMP_DIR}/release-job"
RELEASE_JOB_GCLOUD_LOG="${TEMP_DIR}/release-job-gcloud.log"
RELEASE_JOB_SLEEP_LOG="${TEMP_DIR}/release-job-sleep.log"
mkdir -p "${RELEASE_JOB_MOCK_BIN}" "${RELEASE_JOB_DIRECTORY}"
ln -s "${SCRIPT_DIR}/fixtures/fake-release-job-gcloud.sh" \
    "${RELEASE_JOB_MOCK_BIN}/gcloud"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'printf "%s\n" "$*" >>"${RELEASE_JOB_SLEEP_LOG}"' \
    >"${RELEASE_JOB_MOCK_BIN}/sleep"
chmod 0700 "${RELEASE_JOB_MOCK_BIN}/sleep"

RELEASE_JOB_COMMIT=0123456789abcdef0123456789abcdef01234567
jq -n --arg commit "${RELEASE_JOB_COMMIT}" '
  {
    commit: $commit,
    runId: "456",
    runAttempt: 1,
    cloud: {
      workloadProjectId: "agora-production-test",
      region: "europe-west1",
      databaseZone: "europe-west1-c"
    }
  }
' >"${RELEASE_JOB_DIRECTORY}/release.json"

reset_release_job_test() {
    : >"${RELEASE_JOB_GCLOUD_LOG}"
    : >"${RELEASE_JOB_SLEEP_LOG}"
    jq -n '{executions: {jsonKeysMigrations: null}}' \
        >"${RELEASE_JOB_DIRECTORY}/operations.json"
}

run_release_job_test() {
    local denials="$1"
    local execution_failed="$2"

    PATH="${RELEASE_JOB_MOCK_BIN}:${PATH}" \
        RELEASE_JOB_GCLOUD_LOG="${RELEASE_JOB_GCLOUD_LOG}" \
        RELEASE_JOB_SLEEP_LOG="${RELEASE_JOB_SLEEP_LOG}" \
        RELEASE_JOB_DENIALS="${denials}" \
        RELEASE_JOB_EXECUTION_FAILED="${execution_failed}" \
        RELEASE_DIRECTORY="${RELEASE_JOB_DIRECTORY}" \
        STATE_BUCKET=agora-state-test \
        RECEIPT_BUCKET=agora-receipts-test \
        GITHUB_SHA="${RELEASE_JOB_COMMIT}" \
        GITHUB_RUN_ID=456 \
        GITHUB_RUN_ATTEMPT=1 \
        "${REPOSITORY_ROOT}/ops/google-release-driver.sh" json-migrations
}

reset_release_job_test
run_release_job_test 2 false \
    >"${TEMP_DIR}/release-job-success.out" \
    2>"${TEMP_DIR}/release-job-success.err"
assert_equal "$(grep -Fc 'run jobs execute' "${RELEASE_JOB_GCLOUD_LOG}")" 3
assert_equal "$(wc -l <"${RELEASE_JOB_SLEEP_LOG}" | tr -d ' ')" 2
assert_equal "$(jq --raw-output '.executions.jsonKeysMigrations' \
    "${RELEASE_JOB_DIRECTORY}/operations.json")" \
    agora-json-keys-migrations-execution1
grep -Fq -- '--wait' "${RELEASE_JOB_GCLOUD_LOG}"
if grep -Fq -- '--async' "${RELEASE_JOB_GCLOUD_LOG}"; then
    printf 'Release jobs must use the native wait operation.\n' >&2
    exit 1
fi
grep -Fq 'Waiting for tag-based Cloud Run authorization' \
    "${TEMP_DIR}/release-job-success.err"

reset_release_job_test
set +e
run_release_job_test 99 false \
    >"${TEMP_DIR}/release-job-denied.out" \
    2>"${TEMP_DIR}/release-job-denied.err"
RELEASE_JOB_DENIED_CODE=$?
set -e
assert_equal "${RELEASE_JOB_DENIED_CODE}" 70
assert_equal "$(grep -Fc 'run jobs execute' "${RELEASE_JOB_GCLOUD_LOG}")" 43
assert_equal "$(wc -l <"${RELEASE_JOB_SLEEP_LOG}" | tr -d ' ')" 42
grep -Fq 'did not authorize agora-json-keys-migrations within seven minutes' \
    "${TEMP_DIR}/release-job-denied.err"

reset_release_job_test
set +e
run_release_job_test 0 true \
    >"${TEMP_DIR}/release-job-execution-failed.out" \
    2>"${TEMP_DIR}/release-job-execution-failed.err"
RELEASE_JOB_EXECUTION_CODE=$?
set -e
assert_equal "${RELEASE_JOB_EXECUTION_CODE}" 70
assert_equal "$(grep -Fc 'run jobs execute' "${RELEASE_JOB_GCLOUD_LOG}")" 1
assert_equal "$(wc -l <"${RELEASE_JOB_SLEEP_LOG}" | tr -d ' ')" 0
assert_equal "$(jq --raw-output '.executions.jsonKeysMigrations' \
    "${RELEASE_JOB_DIRECTORY}/operations.json")" null
grep -Fq 'mock execution failure: agora-json-keys-migrations-execution1' \
    "${TEMP_DIR}/release-job-execution-failed.err"

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
    '    if [ "${INIT_EXISTING_MARKER:-false}" = true ]; then' \
    '        if [ "$5" = "--format=value(name)" ]; then printf "%s\n" "production/initialization/1001/complete.json";' \
    '        else printf "%s\n" "https://storage.googleapis.com/storage/v1/b/agora-receipts-test/o/production/initialization/1001/complete.json#123456"; fi' \
    '    fi' \
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

INIT_MARKER_JSON='{"schemaVersion":2,"project":"agora-production-test","dataDiskId":"1001","commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","execution":"agora-authentication-init-valid","completedAt":"2026-08-25T12:00:00Z"}'
INIT_UPLOAD_LOG="${TEMP_DIR}/init-upload.log"
PATH="${INIT_MOCK_BIN}:${PATH}" \
    INIT_EXISTING_MARKER=true \
    INIT_MARKER_JSON="${INIT_MARKER_JSON}" \
    INIT_UPLOAD_LOG="${INIT_UPLOAD_LOG}" \
    "${REPOSITORY_ROOT}/ops/await-auth-initialization.sh" \
    agora-production-test europe-west1 agora-receipts-test \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1001 \
    >"${TEMP_DIR}/init-existing.out"
assert_equal "$(<"${TEMP_DIR}/init-existing.out")" agora-authentication-init-valid

set +e
PATH="${INIT_MOCK_BIN}:${PATH}" \
    INIT_LIST_FAILURE=true \
    INIT_MARKER_JSON="${INIT_MARKER_JSON}" \
    INIT_UPLOAD_LOG="${INIT_UPLOAD_LOG}" \
    "${REPOSITORY_ROOT}/ops/await-auth-initialization.sh" \
    agora-production-test europe-west1 agora-receipts-test \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1001 \
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
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1001 \
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
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1001 \
    >"${TEMP_DIR}/init-success.out" 2>"${TEMP_DIR}/init-success.err"
assert_equal "$(<"${TEMP_DIR}/init-success.out")" agora-authentication-init-success
assert_equal "$(grep -Fc uploaded "${INIT_UPLOAD_LOG}")" 1

STORAGE_MOCK_BIN="${TEMP_DIR}/storage-bin"
FAKE_GCS_ROOT="${TEMP_DIR}/gcs"
mkdir -p "${STORAGE_MOCK_BIN}" "${FAKE_GCS_ROOT}"
ln -s "${SCRIPT_DIR}/fixtures/fake-gcloud-storage.sh" "${STORAGE_MOCK_BIN}/gcloud"

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


set +e
INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
    INFRA_WORKLOAD_PROJECT_ID=INVALID \
    "${REPOSITORY_ROOT}/ops/foundation.sh" configure >/dev/null 2>&1
INVALID_FOUNDATION_PROJECT_CODE=$?
INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
    INFRA_WORKLOAD_PROJECT_ID=INVALID \
    "${REPOSITORY_ROOT}/ops/foundation-audit.sh" >/dev/null 2>&1
INVALID_FOUNDATION_AUDIT_PROJECT_CODE=$?
set -e
[ "${INVALID_FOUNDATION_PROJECT_CODE}" -ne 0 ]
[ "${INVALID_FOUNDATION_AUDIT_PROJECT_CODE}" -ne 0 ]

# Foundation configuration derives every coordinate in a fresh process, writes
# only the protected JSON document, and keeps billing/human metadata off stdout.
WORKFLOW_SHA='1234567890abcdef1234567890abcdef12345678'
FOUNDATION_MOCK_BIN="${TEMP_DIR}/foundation-bin"
FOUNDATION_CALLS="${TEMP_DIR}/foundation-calls"
FOUNDATION_SECRETS="${TEMP_DIR}/foundation-secrets"
mkdir -p "${FOUNDATION_MOCK_BIN}"
ln -s "${SCRIPT_DIR}/fixtures/fake-foundation-gh.sh" "${FOUNDATION_MOCK_BIN}/gh"
ln -s "${SCRIPT_DIR}/fixtures/fake-foundation-gcloud.sh" "${FOUNDATION_MOCK_BIN}/gcloud"
ln -s "${SCRIPT_DIR}/fixtures/fake-operator-git.sh" "${FOUNDATION_MOCK_BIN}/git"
: >"${FOUNDATION_CALLS}"
: >"${FOUNDATION_SECRETS}"
FOUNDATION_OUTPUT="$(
    PATH="${FOUNDATION_MOCK_BIN}:${PATH}" \
        FAKE_FOUNDATION_CALLS="${FOUNDATION_CALLS}" \
        FAKE_FOUNDATION_SECRETS="${FOUNDATION_SECRETS}" \
        FAKE_GIT_SHA="${WORKFLOW_SHA}" \
        INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
        INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
        INFRA_REGION=europe-west1 \
        INFRA_DATABASE_ZONE=europe-west1-d \
        INFRA_COST_ALERT_EMAIL=costs@example.com \
        INFRA_OPERATIONS_ALERT_EMAIL=operations@example.com \
        INFRA_DATABASE_OPERATOR_PRINCIPALS='group:database-operators@example.com user:second@example.com' \
        INFRA_AUTH_INITIALIZER_PRINCIPALS='group:authentication-initializers@example.com' \
        "${REPOSITORY_ROOT}/ops/foundation.sh" configure
)"
grep -Fq 'PASS protected foundation environment' <<<"${FOUNDATION_OUTPUT}"
grep -Fq 'PASS protected foundation configuration' <<<"${FOUNDATION_OUTPUT}"
assert_equal "$(wc -l <"${FOUNDATION_SECRETS}" | tr -d ' ')" 2
grep -Fq -- '--env production-foundation' "${FOUNDATION_SECRETS}"
grep -Fq -- '--env production-recovery' "${FOUNDATION_SECRETS}"
grep -Fq '"workload_project_id":"workload-project-prod"' "${FOUNDATION_SECRETS}"
grep -Fq '"organization_id":"123456789012"' "${FOUNDATION_SECRETS}"
grep -Fq '"region":"europe-west1"' "${FOUNDATION_SECRETS}"
grep -Fq '"database_zone":"europe-west1-d"' "${FOUNDATION_SECRETS}"
grep -Fq '"database_operator_principals":["group:database-operators@example.com","user:second@example.com"]' "${FOUNDATION_SECRETS}"
grep -Fq '"authentication_initializer_principals":["group:authentication-initializers@example.com"]' "${FOUNDATION_SECRETS}"
grep -Fq '"cost_alert_email":"costs@example.com"' "${FOUNDATION_SECRETS}"
grep -Fq '"operations_alert_email":"operations@example.com"' "${FOUNDATION_SECRETS}"
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
    FAKE_GIT_SHA="${WORKFLOW_SHA}" \
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
        FAKE_GIT_SHA="${WORKFLOW_SHA}" \
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

# Validate Google's service-agent exception without weakening the invocation allowlist.
assert_foundation_cloud_run_boundary() {
    local mode="$1"
    local expected_code="$2"
    local output_file="${TEMP_DIR}/foundation-audit-cloud-run-${mode}.out"
    local error_file="${TEMP_DIR}/foundation-audit-cloud-run-${mode}.err"
    local code=0

    : >"${FOUNDATION_CALLS}"
    set +e
    PATH="${FOUNDATION_AUDIT_MOCK_BIN}:${PATH}" \
        FAKE_FOUNDATION_CALLS="${FOUNDATION_CALLS}" \
        FAKE_FOUNDATION_SECRETS="${FOUNDATION_SECRETS}" \
        FAKE_FOUNDATION_SERVICE_MODE=allowed \
        FAKE_FOUNDATION_IAM_MODE="$mode" \
        INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
        INFRA_WORKLOAD_PROJECT_ID=workload-project-prod \
        "${REPOSITORY_ROOT}/ops/foundation-audit.sh" \
        >"$output_file" 2>"$error_file"
    code=$?
    set -e
    assert_equal "$code" "$expected_code"
}

assert_foundation_cloud_run_boundary valid-service-agent 64
grep -Fq 'PASS database operator project IAM' \
    "${TEMP_DIR}/foundation-audit-cloud-run-valid-service-agent.out"
grep -Fq 'PASS Cloud Run service agent IAM' \
    "${TEMP_DIR}/foundation-audit-cloud-run-valid-service-agent.out"
grep -Fq 'PASS conditional Cloud Run invocation IAM' \
    "${TEMP_DIR}/foundation-audit-cloud-run-valid-service-agent.out"

assert_foundation_cloud_run_boundary missing-operator-api-access 70
grep -Fq 'FAIL database operator project IAM' \
    "${TEMP_DIR}/foundation-audit-cloud-run-missing-operator-api-access.err"

assert_foundation_cloud_run_boundary wrong-service-agent 70
grep -Fq 'FAIL Cloud Run service agent IAM' \
    "${TEMP_DIR}/foundation-audit-cloud-run-wrong-service-agent.err"

assert_foundation_cloud_run_boundary unexpected-run-role 70
grep -Fq 'PASS Cloud Run service agent IAM' \
    "${TEMP_DIR}/foundation-audit-cloud-run-unexpected-run-role.out"
grep -Fq 'FAIL conditional Cloud Run invocation IAM' \
    "${TEMP_DIR}/foundation-audit-cloud-run-unexpected-run-role.err"

for mode in missing-smoke-invoker widened-smoke-invoker; do
    assert_foundation_cloud_run_boundary "$mode" 70
    grep -Fq 'FAIL conditional Cloud Run invocation IAM' \
        "${TEMP_DIR}/foundation-audit-cloud-run-${mode}.err"
done

# The one local bootstrap apply uses an external binary plan plus non-secret
# commit/checksum custody and consumes that review before mutation.
BOOTSTRAP_MOCK_BIN="${TEMP_DIR}/bootstrap-bin"
BOOTSTRAP_PLAN="${TEMP_DIR}/bootstrap-plan.tfplan"
BOOTSTRAP_CALLS="${TEMP_DIR}/bootstrap-calls"
mkdir -p "${BOOTSTRAP_MOCK_BIN}"
ln -s "${SCRIPT_DIR}/fixtures/fake-foundation-gcloud.sh" "${BOOTSTRAP_MOCK_BIN}/gcloud"
ln -s "${SCRIPT_DIR}/fixtures/fake-foundation-gh.sh" "${BOOTSTRAP_MOCK_BIN}/gh"
ln -s "${SCRIPT_DIR}/fixtures/fake-operator-git.sh" "${BOOTSTRAP_MOCK_BIN}/git"
ln -s "${SCRIPT_DIR}/fixtures/fake-tofu.sh" "${BOOTSTRAP_MOCK_BIN}/tofu"
: >"${BOOTSTRAP_CALLS}"
set +e
PATH="${BOOTSTRAP_MOCK_BIN}:${PATH}" \
    FAKE_FOUNDATION_CALLS="${BOOTSTRAP_CALLS}" \
    FAKE_FOUNDATION_SECRETS="${FOUNDATION_SECRETS}" \
    FAKE_GIT_SHA="${WORKFLOW_SHA}" \
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
    FAKE_FOUNDATION_SECRETS="${FOUNDATION_SECRETS}" \
    FAKE_GIT_SHA="${WORKFLOW_SHA}" \
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
