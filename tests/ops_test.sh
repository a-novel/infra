#!/bin/bash

# Exercises the root allowlist and sanitized destructive-plan classifier.

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
assert_absent "${TEMP_DIR}/safe.out" "fixture-secret-must-not-be-printed"
assert_absent "${TEMP_DIR}/safe.out" "fixture-password"
assert_absent "${TEMP_DIR}/safe.out" "fixture-token-must-not-be-printed"

set +e
"${REPOSITORY_ROOT}/ops/plan-summary.sh" foundation "${SCRIPT_DIR}/fixtures/plans/protected.json" >"${TEMP_DIR}/protected.out" 2>"${TEMP_DIR}/protected.err"
PROTECTED_CODE=$?
set -e
assert_equal "${PROTECTED_CODE}" "3"
grep -Fq $'delete\tgoogle_project\t1' "${TEMP_DIR}/protected.out"
grep -Fq $'replace\tgoogle_compute_disk\t1' "${TEMP_DIR}/protected.out"
grep -Fq "google_compute_disk (1)" "${TEMP_DIR}/protected.err"
grep -Fq "google_project (1)" "${TEMP_DIR}/protected.err"
grep -Fq "google_service_account (1)" "${TEMP_DIR}/protected.err"
grep -Fq "google_storage_managed_folder (1)" "${TEMP_DIR}/protected.err"
assert_absent "${TEMP_DIR}/protected.out" "fixture-disk-name"
assert_absent "${TEMP_DIR}/protected.err" "fixture-project-id"

if grep -RqE 'resource[[:space:]]+"(google_secret_manager_secret_version|google_service_account_key)"' "${REPOSITORY_ROOT}/bootstrap" --include='*.tf'; then
    printf "Bootstrap must not place secret payloads or service-account keys in state.\n" >&2
    exit 1
fi

if grep -RqE 'roles/(owner|editor)' "${REPOSITORY_ROOT}/bootstrap" --include='*.tf'; then
    printf "Bootstrap automation must not use primitive Owner or Editor roles.\n" >&2
    exit 1
fi

if grep -Fq 'allowed_audiences' "${REPOSITORY_ROOT}/bootstrap/identity.tf"; then
    printf "GitHub federation must use Google's canonical default audience.\n" >&2
    exit 1
fi

printf "Root and plan-policy fixtures passed.\n"
