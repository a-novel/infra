#!/bin/bash

# Verifies exact trusted assessment evidence and current maintainer approval before merge.
# Usage: verify-resource-deletion-gate.sh <owner/repository>

set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s <owner/repository>\n' "$0" >&2
    exit 64
fi

REPOSITORY="$1"
EVENT_NAME="${GITHUB_EVENT_NAME:-}"
CHECK_SHA="${GITHUB_SHA:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REQUIRED_LABEL='allow-resource-deletion'

if ! [[ "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    ! [[ "${CHECK_SHA}" =~ ^[a-f0-9]{40}$ ]]; then
    printf 'The resource-deletion gate input is invalid.\n' >&2
    exit 65
fi

for command_name in gh jq; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required by the resource-deletion gate.\n' "${command_name}" >&2
        exit 69
    fi
done

PULL_REQUEST=''
HEAD_SHA=''
BASE_SHA=''
case "${EVENT_NAME}" in
    pull_request)
        PULL_REQUEST="${GATE_PULL_REQUEST:-}"
        HEAD_SHA="${GATE_HEAD_SHA:-}"
        BASE_SHA="${GATE_BASE_SHA:-}"
        ;;
    merge_group)
        PULL_REQUEST="$(printf '%s' "${GATE_MERGE_HEAD_REF:-}" |
            grep -oE 'pr-[0-9]+' | head -n1 | grep -oE '[0-9]+' || true)"
        BASE_SHA="${GATE_BASE_SHA:-}"
        ;;
    push)
        if [ "${GITHUB_REF:-}" = refs/heads/master ]; then
            printf 'The resource-deletion gate is not applicable after the protected merge.\n'
            exit 0
        fi
        if ! ASSOCIATED_PULLS="$(gh api \
            "repos/${REPOSITORY}/commits/${CHECK_SHA}/pulls" 2>/dev/null)"; then
            printf 'Could not resolve the pull request for this branch commit.\n' >&2
            exit 70
        fi
        if ! TARGET="$(jq --exit-status --compact-output --arg head "${CHECK_SHA}" '
          [
            .[]
            | select(.state == "open" and .base.ref == "master" and .head.sha == $head)
          ]
          | if length == 1 then .[0] else error("pull request missing or ambiguous") end
        ' <<<"${ASSOCIATED_PULLS}" 2>/dev/null)"; then
            printf 'The branch commit does not identify one open pull request to master.\n' >&2
            exit 77
        fi
        PULL_REQUEST="$(jq --raw-output '.number' <<<"${TARGET}")"
        HEAD_SHA="${CHECK_SHA}"
        BASE_SHA="$(jq --raw-output '.base.sha' <<<"${TARGET}")"
        ;;
    *)
        printf 'The resource-deletion gate must run for a pull request, branch push, or merge group.\n' >&2
        exit 65
        ;;
esac

if ! [[ "${PULL_REQUEST}" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "${BASE_SHA}" =~ ^[a-f0-9]{40}$ ]]; then
    printf 'The gate event does not identify an exact pull request and base.\n' >&2
    exit 77
fi

if ! PR_METADATA="$(gh api "repos/${REPOSITORY}/pulls/${PULL_REQUEST}" 2>/dev/null)"; then
    printf 'Could not read the pull request for the resource-deletion gate.\n' >&2
    exit 70
fi

if [ -z "${HEAD_SHA}" ]; then
    HEAD_SHA="$(jq --raw-output '.head.sha // empty' <<<"${PR_METADATA}")"
fi
if ! [[ "${HEAD_SHA}" =~ ^[a-f0-9]{40}$ ]]; then
    printf 'The gate event does not identify an exact candidate commit.\n' >&2
    exit 77
fi
if ! jq --exit-status \
    --arg repository "${REPOSITORY}" \
    --arg head "${HEAD_SHA}" \
    --arg base "${BASE_SHA}" '
      .state == "open" and
      .base.ref == "master" and
      .base.repo.full_name == $repository and
      .head.sha == $head and
      .base.sha == $base
    ' <<<"${PR_METADATA}" >/dev/null; then
    printf 'The pull request moved after the assessed head and base were selected.\n' >&2
    exit 77
fi

TEMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf -- "${TEMP_DIR}"
}
trap cleanup INT TERM EXIT

if ! gh api --paginate --slurp \
    "repos/${REPOSITORY}/pulls/${PULL_REQUEST}/files?per_page=100" \
    --jq 'flatten' >"${TEMP_DIR}/files.json" 2>/dev/null; then
    printf 'Could not inventory the pull-request files.\n' >&2
    exit 70
fi
IMPACT="$("${SCRIPT_DIR}/resource-deletion-impact.sh" "${TEMP_DIR}/files.json")"
if [ "$(jq --raw-output '.required' <<<"${IMPACT}")" != true ]; then
    printf 'The pull request cannot change a production OpenTofu plan.\n'
    exit 0
fi

RUN_TITLE="resource-deletion assessment PR #${PULL_REQUEST} ${HEAD_SHA} onto ${BASE_SHA}"
if ! RUN_PAGES="$(gh api --paginate --slurp \
    "repos/${REPOSITORY}/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&per_page=100" \
    2>/dev/null)"; then
    printf 'Could not inventory resource-deletion assessment runs.\n' >&2
    exit 70
fi

RUN="$(jq --compact-output --arg title "${RUN_TITLE}" '
  [
    .[]
    | .workflow_runs[]?
    | select(.display_title == $title)
  ]
  | sort_by(.id)
  | last // empty
' <<<"${RUN_PAGES}")"
if [ -z "${RUN}" ]; then
    printf 'The exact pull-request head and base need a trusted resource-deletion assessment.\n' >&2
    exit 77
fi

if ! jq --exit-status --arg base "${BASE_SHA}" '
  .path == ".github/workflows/drift.yaml" and
  .event == "workflow_dispatch" and
  .head_branch == "master" and
  .head_sha == $base and
  .status == "completed" and
  .conclusion == "success" and
  (.run_attempt | type == "number" and . >= 1)
' <<<"${RUN}" >/dev/null; then
    printf 'The latest matching resource-deletion assessment did not succeed.\n' >&2
    exit 77
fi

RUN_ID="$(jq --raw-output '.id' <<<"${RUN}")"
RUN_ATTEMPT="$(jq --raw-output '.run_attempt' <<<"${RUN}")"
ARTIFACT_NAME="resource-deletion-assessment-${RUN_ATTEMPT}"
if ! ARTIFACTS="$(gh api \
    "repos/${REPOSITORY}/actions/runs/${RUN_ID}/artifacts?per_page=100" 2>/dev/null)"; then
    printf 'Could not inventory the assessment artifact.\n' >&2
    exit 70
fi
if ! ARTIFACT_ID="$(jq --exit-status --raw-output --arg name "${ARTIFACT_NAME}" '
  [
    .artifacts[]?
    | select(.name == $name and .expired == false)
    | .id
  ]
  | if length == 1 then .[0] else error("artifact missing or ambiguous") end
' <<<"${ARTIFACTS}" 2>/dev/null)"; then
    printf 'The successful assessment has no exact current verdict artifact.\n' >&2
    exit 77
fi
if ! [[ "${ARTIFACT_ID}" =~ ^[1-9][0-9]*$ ]] ||
    ! gh run download "${RUN_ID}" --repo "${REPOSITORY}" \
        --name "${ARTIFACT_NAME}" --dir "${TEMP_DIR}/artifact" >/dev/null 2>&1; then
    printf 'Could not read the assessment verdict artifact.\n' >&2
    exit 70
fi

ASSESSMENT_FILE="${TEMP_DIR}/artifact/assessment.json"
if [ ! -f "${ASSESSMENT_FILE}" ] ||
    ! jq --exit-status \
        --arg repository "${REPOSITORY}" \
        --argjson pull_request "${PULL_REQUEST}" \
        --arg head "${HEAD_SHA}" \
        --arg base "${BASE_SHA}" '
      type == "object" and
      (keys | sort) == ([
        "approvalRequired", "baseSha", "firstLaunch", "headSha",
        "pullRequest", "repository", "schemaVersion"
      ] | sort) and
      .schemaVersion == 1 and
      .repository == $repository and
      .pullRequest == $pull_request and
      .headSha == $head and
      .baseSha == $base and
      (.approvalRequired | type) == "boolean" and
      (.firstLaunch | type) == "boolean" and
      (.firstLaunch == false or .approvalRequired == true)
    ' "${ASSESSMENT_FILE}" >/dev/null; then
    printf 'The assessment verdict is malformed, mismatched, or stale.\n' >&2
    exit 77
fi

if [ "$(jq --raw-output '.approvalRequired' "${ASSESSMENT_FILE}")" = false ]; then
    printf 'The exact trusted assessment found no deletion approval requirement.\n'
    exit 0
fi

if ! jq --exit-status --arg label "${REQUIRED_LABEL}" '
  any(.labels[]?; .name == $label)
' <<<"${PR_METADATA}" >/dev/null; then
    printf 'The %s label must remain present until merge.\n' "${REQUIRED_LABEL}" >&2
    exit 77
fi

"${SCRIPT_DIR}/verify-deletion-label.sh" "${REPOSITORY}" "${PULL_REQUEST}"
