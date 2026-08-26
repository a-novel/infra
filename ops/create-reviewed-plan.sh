#!/bin/bash

# Create one exact saved plan, enforce the deletion-label exception against the
# commit's merged PR, and place the opaque plan in private 24-hour custody.
# Usage: create-reviewed-plan.sh <root> <bucket> <commit> <plan-id> <tfvars>

set -euo pipefail

if [ "$#" -ne 5 ]; then
    printf 'Usage: %s <root> <bucket> <commit> <plan-id> <tfvars>\n' "$0" >&2
    exit 64
fi

ROOT_NAME="$1"
STATE_BUCKET="$2"
COMMIT="$3"
PLAN_ID="$4"
TOFU_VAR_FILE="$5"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLAN_FILE="$(mktemp)"
trap 'rm -f -- "${PLAN_FILE}"' EXIT
chmod 600 "${PLAN_FILE}"

plan_once() {
    set +e
    TOFU_VAR_FILE="${TOFU_VAR_FILE}" \
        "${SCRIPT_DIR}/tofu-gate.sh" plan \
        "${ROOT_NAME}" "${STATE_BUCKET}" "${PLAN_FILE}"
    PLAN_CODE=$?
    set -e
}

DESTRUCTIVE=false
plan_once
if [ "${PLAN_CODE}" -eq 3 ]; then
    "${SCRIPT_DIR}/verify-deletion-label.sh" \
        "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" "${COMMIT}" >/dev/null
    DESTRUCTIVE=true
    ALLOW_RESOURCE_DELETION=true plan_once
fi

if [ "${PLAN_CODE}" -ne 0 ] && [ "${PLAN_CODE}" -ne 2 ]; then
    exit "${PLAN_CODE}"
fi

"${SCRIPT_DIR}/plan-custody.sh" publish \
    "${STATE_BUCKET}" "${ROOT_NAME}" "${COMMIT}" "${PLAN_ID}" \
    "${PLAN_FILE}" "${DESTRUCTIVE}"
