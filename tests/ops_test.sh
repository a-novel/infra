#!/bin/bash

# Exercises the root allowlist and fail-closed destructive-plan classifier.

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
        printf "Sensitive fixture text appeared in plan output.\n" >&2
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

"${REPOSITORY_ROOT}/ops/plan-summary.sh" foundation "${SCRIPT_DIR}/fixtures/plans/safe.json" >"${TEMP_DIR}/safe.out" 2>"${TEMP_DIR}/safe.err"
grep -Fq $'create\tgoogle_cloud_run_v2_job\t1' "${TEMP_DIR}/safe.out"
grep -Fq $'update\tgoogle_cloud_run_v2_service\t1' "${TEMP_DIR}/safe.out"
if grep -Fq $'no-op\t' "${TEMP_DIR}/safe.out"; then
    printf "No-op resources must not appear in the sanitized summary.\n" >&2
    exit 1
fi
assert_absent "${TEMP_DIR}/safe.out" "fixture-secret-must-not-be-printed"
assert_absent "${TEMP_DIR}/safe.out" "fixture-password"
assert_absent "${TEMP_DIR}/safe.out" "fixture-token-must-not-be-printed"

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

# Cloud Quotas omits the default-false reconciling field on some settled
# responses. Omission is accepted, while a pending preference still fails.
PREFLIGHT_MOCK_BIN="${TEMP_DIR}/preflight-bin"
mkdir -p "${PREFLIGHT_MOCK_BIN}"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/bash' \
    'if [ "$1 $2 $3" = "secrets versions describe" ]; then' \
    '    printf "ENABLED\n"' \
    'elif [ "$1 $2 $3" = "quotas preferences list" ]; then' \
    '    jq --argjson pending "${PREFLIGHT_PENDING:-false}" '\''
    [
      {service:"run.googleapis.com", dimensions:{region:"europe-west1"}, justification:"Agora production cost ceiling; changes require reviewed infrastructure code.", quotaConfig:{preferredValue:"8000", grantedValue:"8000"}},
      {service:"run.googleapis.com", dimensions:{region:"europe-west1"}, justification:"Agora production cost ceiling; changes require reviewed infrastructure code.", quotaConfig:{preferredValue:"17179869184", grantedValue:"17179869184"}},
      {service:"run.googleapis.com", dimensions:{region:"europe-west1"}, justification:"Agora production cost ceiling; changes require reviewed infrastructure code.", quotaConfig:{preferredValue:"20", grantedValue:"20"}},
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
    cloud: {
      managementProjectId: "agora-management-test",
      workloadProjectId: "agora-production-test",
      region: "europe-west1",
      secretVersions: [],
      quotaExpectations: {
        cloud_run_cpu_millicpu: 8000,
        cloud_run_memory_bytes: 17179869184,
        cloud_run_direct_vpc_instances: 20,
        compute_cpu: 4
      }
    }
  }
' >"${TEMP_DIR}/preflight.json"
PATH="${PREFLIGHT_MOCK_BIN}:${PATH}" \
    "${REPOSITORY_ROOT}/ops/preflight-release.sh" \
    "${TEMP_DIR}/preflight.json" >"${TEMP_DIR}/preflight.out"

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
    '    printf "[{\"name\":\"agora-scheduled-snapshot\",\"autoCreated\":%s,\"sourceDisk\":\"https://www.googleapis.com/compute/v1/projects/agora-production-test/zones/europe-west1-b/disks/agora-data\",\"status\":\"READY\",\"creationTimestamp\":\"%s\",\"storageLocations\":[\"europe-west1\"],\"labels\":{\"application\":\"agora\",\"environment\":\"production\",\"managed-by\":\"opentofu\",\"plane\":\"workload\",\"role\":\"database-snapshot\"}}]\n" "${snapshot_auto_created}" "${snapshot_time}"' \
    'fi' \
    >"${MOCK_BIN}/gcloud"
chmod 0700 "${MOCK_BIN}/gcloud"

DUMMY_DIGEST="$(printf 'a%.0s' {1..64})"
JSON_KEYS_IMAGE="europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-json-keys/database@sha256:${DUMMY_DIGEST}"
AUTHENTICATION_IMAGE="europe-west1-docker.pkg.dev/agora-production-test/agora-production/service-authentication/database@sha256:${DUMMY_DIGEST}"

PATH="${MOCK_BIN}:${PATH}" GCLOUD_ARGUMENT_LOG="${GCLOUD_ARGUMENT_LOG}" \
    "${REPOSITORY_ROOT}/ops/deploy-database-release.sh" \
    agora-production-test \
    europe-west1-b \
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
    europe-west1-b \
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
    europe-west1-b \
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
    europe-west1-b \
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
    europe-west1-b \
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
    europe-west1-b \
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
    europe-west1-b \
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
    europe-west1-b \
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

printf "Root and plan-policy fixtures passed.\n"
