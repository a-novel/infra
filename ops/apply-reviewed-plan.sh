#!/bin/bash

# Fetch and apply only the exact unexpired plan selected by root, commit, and
# plan ID. Destructive plans re-check the merged PR label immediately before
# apply. The plan object is consumed before mutation and the resulting state
# must converge; a failed attempt therefore requires a newly reviewed plan.
# Usage: apply-reviewed-plan.sh <root> <bucket> <commit> <plan-id> <tfvars>

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
trap 'rm -f -- "${PLAN_FILE}" "${PLAN_FILE}.destructive"' EXIT
chmod 600 "${PLAN_FILE}"

"${SCRIPT_DIR}/plan-custody.sh" fetch \
    "${STATE_BUCKET}" "${ROOT_NAME}" "${COMMIT}" "${PLAN_ID}" "${PLAN_FILE}"

ALLOW_RESOURCE_DELETION=false
if [ "$(<"${PLAN_FILE}.destructive")" = true ]; then
    "${SCRIPT_DIR}/verify-deletion-label.sh" \
        "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" "${COMMIT}" >/dev/null
    ALLOW_RESOURCE_DELETION=true
fi

"${SCRIPT_DIR}/plan-custody.sh" consume \
    "${STATE_BUCKET}" "${ROOT_NAME}" "${COMMIT}" "${PLAN_ID}"

ALLOW_RESOURCE_DELETION="${ALLOW_RESOURCE_DELETION}" \
TOFU_VAR_FILE="${TOFU_VAR_FILE}" \
    "${SCRIPT_DIR}/tofu-gate.sh" apply \
    "${ROOT_NAME}" "${STATE_BUCKET}" "${PLAN_FILE}"

ALLOW_RESOURCE_DELETION="${ALLOW_RESOURCE_DELETION}" \
TOFU_VAR_FILE="${TOFU_VAR_FILE}" \
    "${SCRIPT_DIR}/tofu-gate.sh" converge "${ROOT_NAME}" "${STATE_BUCKET}"
