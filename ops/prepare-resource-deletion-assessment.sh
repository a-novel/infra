#!/bin/bash

# Builds a payload-free deletion verdict from trusted tooling and an exact candidate checkout.
# Usage: prepare-resource-deletion-assessment.sh <repository> <pr> <head> <base> <candidate> <state-bucket> <output>

set -euo pipefail

if [ "$#" -ne 7 ]; then
    printf 'Usage: %s <repository> <pr> <head> <base> <candidate> <state-bucket> <output>\n' "$0" >&2
    exit 64
fi

REPOSITORY="$1"
PULL_REQUEST="$2"
HEAD_SHA="$3"
BASE_SHA="$4"
CANDIDATE_ROOT="$5"
STATE_BUCKET="$6"
OUTPUT_FILE="$7"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! [[ "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    ! [[ "${PULL_REQUEST}" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "${HEAD_SHA}" =~ ^[a-f0-9]{40}$ ]] ||
    ! [[ "${BASE_SHA}" =~ ^[a-f0-9]{40}$ ]] ||
    ! [[ "${STATE_BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,221}[a-z0-9]$ ]] ||
    [[ "${CANDIDATE_ROOT}" != /* ]] || [ ! -d "${CANDIDATE_ROOT}" ]; then
    printf 'The resource-deletion assessment input is invalid.\n' >&2
    exit 65
fi

for command_name in gh git jq tofu; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required by the trusted assessment workflow.\n' "${command_name}" >&2
        exit 69
    fi
done

CANDIDATE_ROOT="$(cd -- "${CANDIDATE_ROOT}" && pwd)"
if [ "$(git -C "${CANDIDATE_ROOT}" rev-parse HEAD)" != "${HEAD_SHA}" ] ||
    [ -n "$(git -C "${CANDIDATE_ROOT}" status --porcelain)" ]; then
    printf 'The candidate checkout differs from the exact assessed commit.\n' >&2
    exit 65
fi

TEMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf -- "${TEMP_DIR}"
}
trap cleanup INT TERM EXIT

if ! PR_METADATA="$(gh api "repos/${REPOSITORY}/pulls/${PULL_REQUEST}" 2>/dev/null)"; then
    printf 'Could not read the pull request while its deletion assessment was starting.\n' >&2
    exit 70
fi
if ! jq --exit-status \
    --arg repository "${REPOSITORY}" \
    --arg head "${HEAD_SHA}" \
    --arg base "${BASE_SHA}" '
  .state == "open" and
  .base.ref == "master" and
  .base.repo.full_name == $repository and
  .head.sha == $head and .base.sha == $base
' <<<"${PR_METADATA}" >/dev/null; then
    printf 'The pull request changed while its deletion assessment was starting.\n' >&2
    exit 77
fi

if ! gh api --paginate --slurp \
    "repos/${REPOSITORY}/pulls/${PULL_REQUEST}/files?per_page=100" 2>/dev/null |
    jq --exit-status 'flatten' >"${TEMP_DIR}/files.json" 2>/dev/null; then
    printf 'Could not inventory the pull-request files.\n' >&2
    exit 70
fi

IMPACT="$("${SCRIPT_DIR}/resource-deletion-impact.sh" "${TEMP_DIR}/files.json")"
RELEASE_ROOT="$(jq --raw-output '.release_root' <<<"${IMPACT}")"
RELEASE_MANIFEST="$(jq --raw-output '.release_manifest' <<<"${IMPACT}")"
mapfile -t ROOTS < <(jq --raw-output '.roots[]' <<<"${IMPACT}")
APPROVAL_REQUIRED=false
FIRST_LAUNCH=false

for root in "${ROOTS[@]}"; do
    config="${TEMP_DIR}/${root}.tfvars.json"
    config_code=0
    if "${SCRIPT_DIR}/config-custody.sh" fetch \
        "${STATE_BUCKET}" "${root}" "${config}"; then
        config_code=0
    else
        config_code=$?
    fi

    if [ "${config_code}" -eq 4 ] && [ "${root}" = release ]; then
        FIRST_LAUNCH=true
        APPROVAL_REQUIRED=true
        printf 'Release has no converged input record; first-launch compensation requires approval.\n'
        continue
    elif [ "${config_code}" -ne 0 ]; then
        printf 'The current %s inputs could not be proven for assessment.\n' "${root}" >&2
        exit 70
    fi

    # First-launch compensation also publishes an empty, converged configuration.
    # Only an active application makes the image-only graph shortcut safe.
    if [ "${root}" = release ] &&
        jq --exit-status '.application_release == null' "${config}" >/dev/null; then
        FIRST_LAUNCH=true
        APPROVAL_REQUIRED=true
        printf 'Release has no active application; first-launch compensation requires approval.\n'
    fi

    if [ "${root}" = release ] && [ "${RELEASE_MANIFEST}" = true ] &&
        [ "${RELEASE_ROOT}" = false ]; then
        if [ "${FIRST_LAUNCH}" = false ]; then
            printf 'The established release image transition keeps the managed-resource graph.\n'
        fi
        continue
    fi

    plan_code=0
    if TOFU_REPOSITORY_ROOT="${CANDIDATE_ROOT}" \
        TOFU_VAR_FILE="${config}" \
        "${SCRIPT_DIR}/tofu-gate.sh" assess "${root}" "${STATE_BUCKET}" \
        >"${TEMP_DIR}/${root}-assessment.log" 2>&1; then
        plan_code=0
    else
        plan_code=$?
    fi

    case "${plan_code}" in
        0) printf '%s candidate assessment completed.\n' "${root}" ;;
        3)
            APPROVAL_REQUIRED=true
            printf '%s candidate requires resource-deletion approval.\n' "${root}"
            ;;
        *)
            printf '%s candidate assessment failed without publishing plan diagnostics.\n' "${root}" >&2
            exit "${plan_code}"
            ;;
    esac
done

mkdir -p -- "$(dirname -- "${OUTPUT_FILE}")"
jq -n \
    --arg repository "${REPOSITORY}" \
    --argjson pull_request "${PULL_REQUEST}" \
    --arg head "${HEAD_SHA}" \
    --arg base "${BASE_SHA}" \
    --argjson approval_required "${APPROVAL_REQUIRED}" \
    --argjson first_launch "${FIRST_LAUNCH}" '
      {
        schemaVersion: 1,
        repository: $repository,
        pullRequest: $pull_request,
        headSha: $head,
        baseSha: $base,
        approvalRequired: $approval_required,
        firstLaunch: $first_launch
      }
    ' >"${OUTPUT_FILE}"
chmod 600 "${OUTPUT_FILE}"
printf 'Resource-deletion assessment recorded without plan or state payloads.\n'
