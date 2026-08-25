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

if grep -RqE 'resource[[:space:]]+"(google_secret_manager_secret_version|google_service_account_key)"' \
    "${REPOSITORY_ROOT}/bootstrap" \
    "${REPOSITORY_ROOT}/environments/production/foundation" \
    --include='*.tf'; then
    printf "Infrastructure must not place secret payloads or service-account keys in state.\n" >&2
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
    '    printf "[{\"name\":\"agora-scheduled-snapshot\",\"autoCreated\":%s,\"sourceDisk\":\"https://www.googleapis.com/compute/v1/projects/agora-production-test/zones/europe-west1-b/disks/agora-data\",\"status\":\"READY\",\"creationTimestamp\":\"%s\",\"storageLocations\":[\"eu\"],\"labels\":{\"application\":\"agora\",\"environment\":\"production\",\"managed-by\":\"opentofu\",\"plane\":\"workload\",\"role\":\"database-snapshot\"}}]\n" "${snapshot_auto_created}" "${snapshot_time}"' \
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

assert_equal "$(grep -Fc 'CALL' "${GCLOUD_ARGUMENT_LOG}")" "6"
grep -Fqx 'describe' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'snapshots' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'list' "${GCLOUD_ARGUMENT_LOG}"
assert_equal "$(grep -Fc 'execute' "${GCLOUD_ARGUMENT_LOG}")" "2"
grep -Fqx 'agora-postgres-backup-json-keys' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'agora-postgres-backup-authentication' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx -- '--wait' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'all-instances-config' "${GCLOUD_ARGUMENT_LOG}"
grep -Fqx 'update-instances' "${GCLOUD_ARGUMENT_LOG}"
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

printf "Root and plan-policy fixtures passed.\n"
