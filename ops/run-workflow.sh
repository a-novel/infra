#!/bin/bash

# Dispatch one allowlisted production workflow from the exact local master,
# identify the run created by that dispatch, and wait unless an in-workflow
# human gate must continue from the printed run URL.
# Usage: run-workflow.sh <workflow> <run-id|run-id-attempt> [--no-wait] [<input>=<value> ...]

set -euo pipefail

if [ "$#" -lt 2 ]; then
    printf 'Usage: %s <workflow> <run-id|run-id-attempt> [--no-wait] [<input>=<value> ...]\n' "$0" >&2
    exit 64
fi

WORKFLOW="$1"
OUTPUT_KIND="$2"
shift 2

case "${WORKFLOW}" in
    drift.yaml | foundation.yaml | recovery.yaml | release.yaml) ;;
    *)
        printf 'Refusing workflow outside the production allowlist: %s\n' "${WORKFLOW}" >&2
        exit 64
        ;;
esac

case "${OUTPUT_KIND}" in
    run-id | run-id-attempt) ;;
    *)
        printf 'Output must be run-id or run-id-attempt.\n' >&2
        exit 64
        ;;
esac

WAIT_FOR_COMPLETION=true
if [ "${1:-}" = --no-wait ]; then
    if [ "${OUTPUT_KIND}" != run-id ]; then
        printf '%s\n' '--no-wait supports only run-id output.' >&2
        exit 64
    fi
    WAIT_FOR_COMPLETION=false
    shift
fi

if [ "$#" -gt 16 ]; then
    printf 'Refusing more than 16 workflow inputs.\n' >&2
    exit 64
fi

WORKFLOW_INPUTS=()
WORKFLOW_INPUT_NAMES=()
for input in "$@"; do
    if ! [[ "${input}" =~ ^[A-Za-z][A-Za-z0-9_-]*=.+$ ]]; then
        printf 'Workflow inputs must use non-empty name=value syntax.\n' >&2
        exit 64
    fi
    input_name="${input%%=*}"
    for existing_name in "${WORKFLOW_INPUT_NAMES[@]}"; do
        if [ "${existing_name}" = "${input_name}" ]; then
            printf 'Refusing duplicate workflow input: %s\n' "${input_name}" >&2
            exit 64
        fi
    done
    WORKFLOW_INPUT_NAMES+=("${input_name}")
    WORKFLOW_INPUTS+=(-f "${input}")
done

for command_name in gh git jq; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required to run a protected workflow.\n' "${command_name}" >&2
        exit 69
    fi
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPOSITORY='a-novel/infra'
DISCOVERY_ATTEMPTS="${WORKFLOW_DISCOVERY_ATTEMPTS:-30}"
DISCOVERY_INTERVAL_SECONDS="${WORKFLOW_DISCOVERY_INTERVAL_SECONDS:-1}"

if ! [[ "${DISCOVERY_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "${DISCOVERY_INTERVAL_SECONDS}" =~ ^[0-9]+$ ]]; then
    printf 'Workflow discovery settings must be non-negative integers with at least one attempt.\n' >&2
    exit 64
fi

if [ "$(git -C "${REPOSITORY_ROOT}" branch --show-current)" != master ]; then
    printf 'Run protected workflows only from the local master branch.\n' >&2
    exit 65
fi
if [ -n "$(git -C "${REPOSITORY_ROOT}" status --porcelain)" ]; then
    printf 'Run protected workflows only from a clean checkout.\n' >&2
    exit 65
fi

LOCAL_SHA="$(git -C "${REPOSITORY_ROOT}" rev-parse HEAD)"
EXPECTED_SHA="${EXPECTED_SHA:-${LOCAL_SHA}}"
if ! [[ "${EXPECTED_SHA}" =~ ^[a-f0-9]{40}$ ]] || [ "${LOCAL_SHA}" != "${EXPECTED_SHA}" ]; then
    printf 'The expected commit must equal the local master commit.\n' >&2
    exit 65
fi

REMOTE_SHA="$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)"
if [ "${REMOTE_SHA}" != "${EXPECTED_SHA}" ]; then
    printf 'Local master does not equal the current remote master.\n' >&2
    exit 65
fi

# All four workflows share one concurrency group. Refusing an already active
# writer avoids silently queueing a second operation behind a waiting approval.
ACTIVE_RUNS="$(gh api "repos/${REPOSITORY}/actions/runs?branch=master&per_page=100" --jq '
    .workflow_runs[]
    | select(.status != "completed")
    | select(
        .path == ".github/workflows/drift.yaml" or
        .path == ".github/workflows/foundation.yaml" or
        .path == ".github/workflows/recovery.yaml" or
        .path == ".github/workflows/release.yaml"
      )
    | [.id, .name, .display_title, .status, .html_url]
    | @tsv
')"
if [ -n "${ACTIVE_RUNS}" ]; then
    printf 'Another production infrastructure run is active:\n%s\n' "${ACTIVE_RUNS}" >&2
    printf 'Wait for it to finish or resolve it before dispatching another run.\n' >&2
    exit 75
fi

BEFORE_RUN_IDS="$(gh run list \
    --repo "${REPOSITORY}" \
    --workflow "${WORKFLOW}" \
    --branch master \
    --event workflow_dispatch \
    --limit 100 \
    --json databaseId \
    --jq '[.[].databaseId]')"

printf 'Dispatching %s from master at %s.\n' "${WORKFLOW}" "${EXPECTED_SHA}" >&2
gh workflow run "${WORKFLOW}" \
    --repo "${REPOSITORY}" \
    --ref master \
    "${WORKFLOW_INPUTS[@]}" >&2

RUN=''
for ((attempt = 1; attempt <= DISCOVERY_ATTEMPTS; attempt++)); do
    CANDIDATES="$(gh run list \
        --repo "${REPOSITORY}" \
        --workflow "${WORKFLOW}" \
        --branch master \
        --event workflow_dispatch \
        --limit 100 \
        --json databaseId,headSha,status,url)"
    MATCHES="$(jq --compact-output \
        --arg expected_sha "${EXPECTED_SHA}" \
        --argjson before "${BEFORE_RUN_IDS}" '
          [
            .[] as $run
            | select($run.headSha == $expected_sha)
            | select(($before | index($run.databaseId)) == null)
            | $run
          ]
        ' <<<"${CANDIDATES}")"
    MATCH_COUNT="$(jq 'length' <<<"${MATCHES}")"
    if [ "${MATCH_COUNT}" -gt 1 ]; then
        printf 'Several new matching workflow runs appeared; refusing to guess.\n' >&2
        exit 70
    fi
    if [ "${MATCH_COUNT}" -eq 1 ]; then
        RUN="$(jq --compact-output '.[0]' <<<"${MATCHES}")"
        break
    fi
    if [ "${attempt}" -lt "${DISCOVERY_ATTEMPTS}" ]; then
        sleep "${DISCOVERY_INTERVAL_SECONDS}"
    fi
done

if [ -z "${RUN}" ]; then
    printf 'The dispatched workflow run did not become visible in time.\n' >&2
    exit 70
fi

RUN_ID="$(jq --raw-output '.databaseId' <<<"${RUN}")"
RUN_URL="$(jq --raw-output '.url' <<<"${RUN}")"
if ! [[ "${RUN_ID}" =~ ^[1-9][0-9]*$ ]] || ! [[ "${RUN_URL}" =~ ^https://github\.com/a-novel/infra/actions/runs/[1-9][0-9]*$ ]]; then
    printf 'GitHub returned invalid workflow run metadata.\n' >&2
    exit 70
fi

printf 'Workflow run: %s\n' "${RUN_URL}" >&2
if [ "${WAIT_FOR_COMPLETION}" = false ]; then
    printf '%s\n' "${RUN_ID}"
    exit 0
fi

gh run watch "${RUN_ID}" --repo "${REPOSITORY}" --exit-status >&2

RUN_METADATA="$(gh api "repos/${REPOSITORY}/actions/runs/${RUN_ID}")"
EXPECTED_PATH=".github/workflows/${WORKFLOW}"
if ! jq --exit-status \
    --arg expected_sha "${EXPECTED_SHA}" \
    --arg expected_path "${EXPECTED_PATH}" '
      .head_sha == $expected_sha and
      .path == $expected_path and
      .event == "workflow_dispatch" and
      .status == "completed" and
      .conclusion == "success" and
      (.run_attempt | type == "number" and . >= 1)
    ' <<<"${RUN_METADATA}" >/dev/null; then
    printf 'The workflow did not finish successfully with the expected identity.\n' >&2
    exit 70
fi

RUN_ATTEMPT="$(jq --raw-output '.run_attempt' <<<"${RUN_METADATA}")"
if [ "${OUTPUT_KIND}" = run-id-attempt ]; then
    printf '%s-%s\n' "${RUN_ID}" "${RUN_ATTEMPT}"
else
    printf '%s\n' "${RUN_ID}"
fi
