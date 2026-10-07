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
    '  "secrets describe production-authentication-waitlist-secret --project=agora-management-test --format=yaml(name,annotations,createTime,versionDestroyTtl)")' \
    '    printf "%s\n" "name: production-authentication-waitlist-secret" ;;' \
    '  "secrets versions add production-authentication-waitlist-secret --project=agora-management-test --data-file=- --quiet --format=value(name.basename())")' \
    '    payload="$(cat)"' \
    '    [ "$payload" = "$FAKE_EXPECTED_SECRET" ]' \
    '    printf "%s" "14" ;;' \
    '  "secrets versions describe 14 --secret=production-authentication-waitlist-secret --project=agora-management-test --format=value(state)")' \
    '    printf "%s" "ENABLED" ;;' \
    '  "secrets versions describe 14 --secret=production-authentication-waitlist-secret --project=agora-management-test --format=yaml(name,state,createTime,destroyTime,scheduledDestroyTime)")' \
    '    printf "%s\n" "state: ENABLED" ;;' \
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

for WAITLIST_KEY in fixture-only-waitlist-signing-key-0123456789 too-short; do
    WAITLIST_CODE=0
    printf '%s\n%s\n' "$WAITLIST_KEY" "$WAITLIST_KEY" \
        | PATH="${SECRET_MOCK_BIN}:${PATH}" \
            FAKE_EXPECTED_SECRET="$WAITLIST_KEY" \
            INFRA_MANAGEMENT_PROJECT_ID=agora-management-test \
            INFRA_WORKLOAD_PROJECT_ID=agora-production-test \
            "${REPOSITORY_ROOT}/ops/add-secret-version.sh" production-authentication-waitlist-secret \
            >"${TEMP_DIR}/waitlist-key.out" 2>"${TEMP_DIR}/waitlist-key.err" || WAITLIST_CODE=$?
    if [ "$WAITLIST_KEY" = too-short ]; then
        assert_equal "$WAITLIST_CODE" 65
        grep -Fq 'Waitlist signing keys require at least 32 characters.' "${TEMP_DIR}/waitlist-key.err"
    else
        assert_equal "$WAITLIST_CODE" 0
        assert_equal "$(<"${TEMP_DIR}/waitlist-key.out")" 'Created production-authentication-waitlist-secret version 14.'
    fi
    assert_absent "${TEMP_DIR}/waitlist-key.out" "$WAITLIST_KEY"
    assert_absent "${TEMP_DIR}/waitlist-key.err" "$WAITLIST_KEY"
done

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

for RETIRED_SECRET in production-authentication-postgres-backup-password production-json-keys-postgres-backup-password; do
    RETIRED_SECRET_CODE=0
    PATH="${SECRET_MOCK_BIN}:${PATH}" \
        "${REPOSITORY_ROOT}/ops/add-secret-version.sh" "$RETIRED_SECRET" \
        >"${TEMP_DIR}/retired-secret.out" 2>"${TEMP_DIR}/retired-secret.err" || RETIRED_SECRET_CODE=$?
    assert_equal "$RETIRED_SECRET_CODE" 65
    grep -Fq 'Refusing undeclared secret ID' "${TEMP_DIR}/retired-secret.err"
done

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
while IFS='|' read -r filename previous_filename expected; do
    jq -n --arg filename "${filename}" --arg previous "${previous_filename}" \
        '[{filename: $filename, previous_filename: $previous}]' >"${TEMP_DIR}/impact.json"
    assert_equal "$("${REPOSITORY_ROOT}/ops/resource-deletion-impact.sh" \
        "${TEMP_DIR}/impact.json" | jq -c '[.required, .roots]')" "${expected}"
done <<'CASES'
README.md||[false,[]]
environments/production/foundation/main.tf||[true,["foundation"]]
deploy/production/images.yaml||[true,["release"]]
docs/old.md|bootstrap/main.tf|[true,["bootstrap"]]
modules/shared/main.tf||[true,["bootstrap","foundation","release","service-foundation","service-release","service-recovery"]]
assets/database-host/startup.sh||[true,["foundation","service-foundation"]]
docs/old.md|assets/database-host/shutdown.sh|[true,["foundation","service-foundation"]]
environments/service-foundation/main.tf||[true,["service-foundation"]]
docs/old.md|environments/service-foundation/main.tf|[true,["service-foundation"]]
environments/service-release/jobs.tf||[true,["service-release"]]
environments/service-release/README.md||[true,["service-release"]]
docs/old.md|environments/service-release/jobs.tf|[true,["service-release"]]
environments/service-recovery/main.tf||[true,["service-recovery"]]
docs/old.md|environments/service-recovery/main.tf|[true,["service-recovery"]]
CASES

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
DELETION_LIVE_BASE=dddddddddddddddddddddddddddddddddddddddd
DELETION_OTHER_GROUP=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

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
    local live_base="${9:-${DELETION_BASE}}"
    local queue_group="${10:-${DELETION_GROUP}}"
    local merge_base="${11:-${DELETION_BASE}}"
    local compare="${12:-unexpected}"
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
        FAKE_GATE_COMPARE="${compare}" \
        FAKE_GATE_FILES="${files}" \
        FAKE_GATE_HEAD="${pull_request_head}" \
        FAKE_GATE_GROUP="${DELETION_GROUP}" \
        FAKE_GATE_LABEL_MODE="${label_mode}" \
        FAKE_GATE_LIVE_BASE="${live_base}" \
        FAKE_GATE_QUEUE_BASE="${merge_base}" \
        FAKE_GATE_QUEUE_GROUP="${queue_group}" \
        FAKE_GATE_RUN_MODE="${run_mode}" \
        GATE_BASE_SHA="${merge_base}" \
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
assert_resource_gate_code 0 image success missing "${SAFE_ASSESSMENT}" merge_group admin "${DELETION_HEAD}" "${DELETION_LIVE_BASE}"
assert_resource_gate_code 77 image success missing "${SAFE_ASSESSMENT}" merge_group admin "${DELETION_HEAD}" "${DELETION_BASE}" "${DELETION_OTHER_GROUP}"

# A merge group reuses the head's assessment onto an earlier base only across commits that cannot
# change a production plan; deletion approval still applies, and pull-request events stay exact.
QUEUED=(admin "${DELETION_HEAD}" "${DELETION_BASE}" "${DELETION_GROUP}" "${DELETION_LIVE_BASE}")
assert_resource_gate_code 0 image success missing "${SAFE_ASSESSMENT}" merge_group "${QUEUED[@]}" plan-neutral
assert_resource_gate_code 77 image success missing "${SAFE_ASSESSMENT}" merge_group "${QUEUED[@]}" production
assert_resource_gate_code 77 image success missing "${SAFE_ASSESSMENT}" merge_group "${QUEUED[@]}" diverged
assert_resource_gate_code 77 image success missing "${SAFE_ASSESSMENT}" merge_group "${QUEUED[@]}" truncated
assert_resource_gate_code 70 image success missing "${SAFE_ASSESSMENT}" merge_group "${QUEUED[@]}" failed
assert_resource_gate_code 77 image failed missing "${SAFE_ASSESSMENT}" merge_group "${QUEUED[@]}" plan-neutral
assert_resource_gate_code 77 image success missing "${DESTRUCTIVE_ASSESSMENT}" merge_group "${QUEUED[@]}" plan-neutral
assert_resource_gate_code 0 image success approved "${DESTRUCTIVE_ASSESSMENT}" merge_group "${QUEUED[@]}" plan-neutral
assert_resource_gate_code 77 image success missing "${SAFE_ASSESSMENT}" pull_request admin "${DELETION_HEAD}" "${DELETION_LIVE_BASE}" "${DELETION_GROUP}" "${DELETION_LIVE_BASE}" plan-neutral

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
grep -Fq $'PERMISSION_DENIED\t-\t-\t1' "${TEMP_DIR}/failed-plan.err"
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
grep -Fq $'PERMISSION_DENIED\t-\t-\t1' "${TEMP_DIR}/failed-apply.err"
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

# Authentication initialization is a one-time observation gate, never an
# automated invocation. Exercise absent, failed, stale, and wrong-job executions
# with a zero-wait fake Cloud Run control plane; Go tests cover stored markers.
INIT_MOCK_BIN="${TEMP_DIR}/init-bin"
mkdir -p "${INIT_MOCK_BIN}"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'if [ "$1 $2 $3" = "storage objects list" ]; then' \
    '    exit 0' \
    'elif [ "$1 $2 $3 $4" = "run jobs executions list" ]; then' \
    '    printf "%s\n" "${INIT_EXECUTIONS_JSON:-[]}"' \
    'elif [ "$1 $2" = "storage cp" ] && [[ "$4" == gs://* ]]; then' \
    '    printf "uploaded\n" >>"${INIT_UPLOAD_LOG}"' \
    'else' \
    '    exit 1' \
    'fi' \
    >"${INIT_MOCK_BIN}/gcloud"
chmod 0700 "${INIT_MOCK_BIN}/gcloud"

INIT_UPLOAD_LOG="${TEMP_DIR}/init-upload.log"

run_failed_init_case() {
    local label="$1"
    local executions="$2"
    local code=0
    set +e
    PATH="${INIT_MOCK_BIN}:${PATH}" \
        INITIALIZATION_MAX_POLLS=1 \
        INITIALIZATION_POLL_SECONDS=0 \
        INIT_EXECUTIONS_JSON="${executions}" \
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
    INIT_UPLOAD_LOG="${INIT_UPLOAD_LOG}" \
    "${REPOSITORY_ROOT}/ops/await-auth-initialization.sh" \
    agora-production-test europe-west1 agora-receipts-test \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1001 \
    >"${TEMP_DIR}/init-success.out" 2>"${TEMP_DIR}/init-success.err"
assert_equal "$(<"${TEMP_DIR}/init-success.out")" agora-authentication-init-success
assert_equal "$(grep -Fc uploaded "${INIT_UPLOAD_LOG}")" 1

set +e
INFRA_MANAGEMENT_PROJECT_ID=management-project-prod \
    INFRA_WORKLOAD_PROJECT_ID=INVALID \
    "${REPOSITORY_ROOT}/ops/foundation-audit.sh" >/dev/null 2>&1
INVALID_FOUNDATION_AUDIT_PROJECT_CODE=$?
set -e
[ "${INVALID_FOUNDATION_AUDIT_PROJECT_CODE}" -ne 0 ]
FOUNDATION_CALLS="${TEMP_DIR}/foundation-calls"

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
WORKFLOW_SHA='1234567890abcdef1234567890abcdef12345678'
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
