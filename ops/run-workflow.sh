#!/bin/bash

# Dispatches one protected infrastructure operation from the exact local master commit.
# Usage: ./ops/run-workflow.sh <drift|foundation|release|recovery> [operation arguments]

set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage:
  $0 drift
  $0 drift assess-pull-request <pull-request-number>
  $0 foundation plan <bootstrap|foundation>
  $0 foundation apply <bootstrap|foundation> <plan-id>
  $0 release deploy [--no-wait]
  $0 release rollback <receipt-id>
  $0 release recover-first-launch <failed-run-id>
  $0 release drill-database-isolation <receipt-id> 'DRILL authentication'
  $0 release restore-database-isolation <receipt-id> 'RESTORE authentication'
  $0 recovery plan-workload <replacement-project-id> <receipt-id>
  $0 recovery apply-workload <replacement-project-id> <receipt-id> <plan-id>
  $0 recovery restore-data <replacement-project-id> <receipt-id> <json-keys-attempt> <authentication-attempt> <lost-write-window> <confirmation>
  $0 recovery cleanup-project <replacement-project-id> <receipt-id> <confirmation>
EOF
    exit 64
}

is_run_attempt() {
    [[ "$1" =~ ^[1-9][0-9]*-[1-9][0-9]*$ ]]
}

is_run_id() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_project_id() {
    [[ "$1" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]]
}

is_backup_attempt() {
    [[ "$1" =~ ^[0-9]+-[a-z0-9-]{1,63}-[0-9]+$ ]]
}

WORKFLOW=''
OUTPUT_KIND='run-id'
WAIT_FOR_COMPLETION=true
PLAN_ID=''
PLAN_WORKFLOW=''
PLAN_TITLE_PREFIX=''
WORKFLOW_INPUTS=()
ASSESSMENT_PR=''

if [ "$#" -lt 1 ]; then
    usage
fi

SURFACE="$1"
shift

case "${SURFACE}" in
    drift)
        if [ "$#" -eq 0 ]; then
            WORKFLOW_INPUTS=(-f 'inputs[operation]=drift')
        elif [ "$#" -eq 2 ] && [ "$1" = assess-pull-request ] && is_run_id "$2"; then
            ASSESSMENT_PR="$2"
        else
            usage
        fi
        WORKFLOW='drift.yaml'
        ;;
    foundation)
        if [ "$#" -lt 2 ]; then
            usage
        fi
        OPERATION="$1"
        ROOT_NAME="$2"
        shift 2
        case "${ROOT_NAME}" in
            bootstrap | foundation) ;;
            *) usage ;;
        esac
        case "${OPERATION}" in
            plan)
                if [ "$#" -ne 0 ]; then
                    usage
                fi
                OUTPUT_KIND='run-id-attempt'
                ;;
            apply)
                if [ "$#" -ne 1 ] || ! is_run_attempt "$1"; then
                    usage
                fi
                PLAN_ID="$1"
                PLAN_WORKFLOW='foundation.yaml'
                PLAN_TITLE_PREFIX="foundation plan ${ROOT_NAME} by @"
                WORKFLOW_INPUTS+=(-f "inputs[plan_id]=${PLAN_ID}")
                ;;
            *) usage ;;
        esac
        WORKFLOW='foundation.yaml'
        WORKFLOW_INPUTS=(-f "inputs[operation]=${OPERATION}" -f "inputs[root]=${ROOT_NAME}" "${WORKFLOW_INPUTS[@]}")
        ;;
    release)
        if [ "$#" -lt 1 ]; then
            usage
        fi
        OPERATION="$1"
        shift
        case "${OPERATION}" in
            deploy)
                if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != '--no-wait' ]; }; then
                    usage
                fi
                if [ "${1:-}" = '--no-wait' ]; then
                    WAIT_FOR_COMPLETION=false
                fi
                WORKFLOW_INPUTS=(-f 'inputs[action]=deploy')
                ;;
            rollback)
                if [ "$#" -ne 1 ] || ! is_run_attempt "$1"; then
                    usage
                fi
                WORKFLOW_INPUTS=(-f 'inputs[action]=rollback' -f "inputs[target_receipt]=$1")
                ;;
            recover-first-launch)
                if [ "$#" -ne 1 ] || ! is_run_id "$1"; then
                    usage
                fi
                WORKFLOW_INPUTS=(-f 'inputs[action]=recover-first-launch' -f "inputs[failed_run_id]=$1")
                ;;
            drill-database-isolation | restore-database-isolation)
                if [ "$#" -ne 2 ] || ! is_run_attempt "$1"; then
                    usage
                fi
                if [ "$OPERATION" = drill-database-isolation ]; then
                    [ "$2" = 'DRILL authentication' ] || usage
                else
                    [ "$2" = 'RESTORE authentication' ] || usage
                fi
                WORKFLOW_INPUTS=(-f "inputs[action]=${OPERATION}" -f "inputs[target_receipt]=$1" -f "inputs[confirm_isolation]=$2")
                ;;
            *) usage ;;
        esac
        WORKFLOW='release.yaml'
        ;;
    recovery)
        if [ "$#" -lt 3 ]; then
            usage
        fi
        OPERATION="$1"
        REPLACEMENT_PROJECT_ID="$2"
        TARGET_RECEIPT="$3"
        shift 3
        if ! is_project_id "${REPLACEMENT_PROJECT_ID}" || ! is_run_attempt "${TARGET_RECEIPT}"; then
            usage
        fi
        WORKFLOW='recovery.yaml'
        case "${OPERATION}" in
            plan-workload)
                if [ "$#" -ne 0 ]; then
                    usage
                fi
                OUTPUT_KIND='run-id-attempt'
                ;;
            apply-workload)
                if [ "$#" -ne 1 ] || ! is_run_attempt "$1"; then
                    usage
                fi
                PLAN_ID="$1"
                PLAN_WORKFLOW='recovery.yaml'
                PLAN_TITLE_PREFIX="recovery plan-workload ${REPLACEMENT_PROJECT_ID} by @"
                WORKFLOW_INPUTS+=(-f "inputs[plan_id]=${PLAN_ID}")
                ;;
            restore-data)
                if [ "$#" -ne 4 ] || ! is_backup_attempt "$1" || ! is_backup_attempt "$2" || \
                    [ -z "$3" ] || [ "${#3}" -gt 500 ] || [[ "$3" =~ [[:cntrl:]] ]] || \
                    [ "$4" != "RESTORE ${REPLACEMENT_PROJECT_ID}" ]; then
                    usage
                fi
                OUTPUT_KIND='run-id-attempt'
                WORKFLOW_INPUTS+=(
                    -f "inputs[json_keys_attempt]=$1"
                    -f "inputs[authentication_attempt]=$2"
                    -f "inputs[lost_write_window]=$3"
                    -f "inputs[confirm]=$4"
                )
                ;;
            cleanup-project)
                if [ "$#" -ne 1 ] || [ "$1" != "DELETE ${REPLACEMENT_PROJECT_ID}" ]; then
                    usage
                fi
                WORKFLOW_INPUTS+=(-f "inputs[confirm]=$1")
                ;;
            *) usage ;;
        esac
        WORKFLOW_INPUTS=(
            -f "inputs[operation]=${OPERATION}"
            -f "inputs[replacement_project_id]=${REPLACEMENT_PROJECT_ID}"
            -f "inputs[target_receipt]=${TARGET_RECEIPT}"
            "${WORKFLOW_INPUTS[@]}"
        )
        ;;
    *) usage ;;
esac

for command_name in gh git jq; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required to run a protected workflow.\n' "${command_name}" >&2
        exit 69
    fi
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPOSITORY='a-novel/infra'

if [ "$(git -C "${REPOSITORY_ROOT}" branch --show-current)" != master ]; then
    printf 'Run protected workflows only from the local master branch.\n' >&2
    exit 65
fi
if [ -n "$(git -C "${REPOSITORY_ROOT}" status --porcelain)" ]; then
    printf 'Run protected workflows only from a clean checkout.\n' >&2
    exit 65
fi

LOCAL_SHA="$(git -C "${REPOSITORY_ROOT}" rev-parse HEAD)"
EXPECTED_SHA="${LOCAL_SHA}"
if [ -n "${PLAN_ID}" ]; then
    PLAN_RUN_ID="${PLAN_ID%-*}"
    PLAN_RUN_ATTEMPT="${PLAN_ID##*-}"
    PLAN_METADATA="$(gh api "repos/${REPOSITORY}/actions/runs/${PLAN_RUN_ID}")"
    if ! jq --exit-status \
        --arg expected_path ".github/workflows/${PLAN_WORKFLOW}" \
        --arg expected_title_prefix "${PLAN_TITLE_PREFIX}" \
        --argjson expected_attempt "${PLAN_RUN_ATTEMPT}" '
          .path == $expected_path and
          (.display_title | startswith($expected_title_prefix)) and
          .event == "workflow_dispatch" and
          .status == "completed" and
          .conclusion == "success" and
          .run_attempt == $expected_attempt and
          (.head_sha | test("^[a-f0-9]{40}$"))
        ' <<<"${PLAN_METADATA}" >/dev/null; then
        printf 'The selected plan ID is not a successful matching workflow attempt.\n' >&2
        exit 65
    fi
    EXPECTED_SHA="$(jq --raw-output '.head_sha' <<<"${PLAN_METADATA}")"
fi

if [ "${LOCAL_SHA}" != "${EXPECTED_SHA}" ]; then
    printf 'The selected plan commit is no longer the local master commit; create a fresh plan.\n' >&2
    exit 65
fi

REMOTE_SHA="$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)"
if [ "${REMOTE_SHA}" != "${EXPECTED_SHA}" ]; then
    printf 'Local master does not equal the required remote master commit.\n' >&2
    exit 65
fi

if [ -n "${ASSESSMENT_PR}" ]; then
    PR_METADATA="$(gh api "repos/${REPOSITORY}/pulls/${ASSESSMENT_PR}")"
    if ! jq --exit-status \
        --arg repository "${REPOSITORY}" \
        --arg base "${REMOTE_SHA}" '
          .state == "open" and
          .base.ref == "master" and
          .base.repo.full_name == $repository and
          .base.sha == $base and
          (.head.sha | test("^[a-f0-9]{40}$"))
        ' <<<"${PR_METADATA}" >/dev/null; then
        printf 'The pull request is not open against the exact current master commit.\n' >&2
        exit 65
    fi
    ASSESSMENT_HEAD="$(jq --raw-output '.head.sha' <<<"${PR_METADATA}")"
    WORKFLOW_INPUTS=(
        -f 'inputs[operation]=assess-pull-request'
        -f "inputs[pull_request]=${ASSESSMENT_PR}"
        -f "inputs[head_sha]=${ASSESSMENT_HEAD}"
        -f "inputs[base_sha]=${REMOTE_SHA}"
    )
fi

# The workflows share one concurrency group. Refusing an active writer avoids
# silently queueing another operation behind a waiting environment approval.
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

printf 'Dispatching %s from master at %s.\n' "${WORKFLOW}" "${EXPECTED_SHA}" >&2
if ! RUN="$(gh api "repos/${REPOSITORY}/actions/workflows/${WORKFLOW}/dispatches" \
    --method POST -H 'X-GitHub-Api-Version: 2026-03-10' \
    -f ref=master "${WORKFLOW_INPUTS[@]}")" ||
    ! jq --exit-status --slurp --arg repository "${REPOSITORY}" '
      length == 1 and (.[0] |
        (.workflow_run_id | type == "number" and . > 0 and . == floor and . <= 9007199254740991) and
        .html_url == ("https://github.com/" + $repository + "/actions/runs/" + (.workflow_run_id | tostring)))
    ' <<<"${RUN}" >/dev/null 2>&1; then
    printf 'Workflow dispatch could not be confirmed; a run may already exist. Inspect https://github.com/%s/actions before retrying.\n' "${REPOSITORY}" >&2
    exit 70
fi

RUN_ID="$(jq --raw-output '.workflow_run_id' <<<"${RUN}")"
RUN_URL="$(jq --raw-output '.html_url' <<<"${RUN}")"

# The dispatch identifies the run; its metadata proves the branch did not move.
read_run_metadata() {
    if ! RUN_METADATA="$(gh api "repos/${REPOSITORY}/actions/runs/${RUN_ID}")" ||
        ! jq --exit-status --argjson id "${RUN_ID}" \
            --arg sha "${EXPECTED_SHA}" --arg path ".github/workflows/${WORKFLOW}" '
              .id == $id and .head_sha == $sha and .path == $path and
              .event == "workflow_dispatch" and .head_branch == "master"
            ' <<<"${RUN_METADATA}" >/dev/null 2>&1; then
        printf 'The workflow identity could not be verified. Inspect %s before retrying.\n' "${RUN_URL}" >&2
        exit 70
    fi
}

read_run_metadata
printf 'Workflow run: %s\n' "${RUN_URL}" >&2
if [ "${WAIT_FOR_COMPLETION}" = false ]; then
    printf '%s\n' "${RUN_ID}"
    exit 0
fi

gh run watch "${RUN_ID}" --repo "${REPOSITORY}" --exit-status >&2

read_run_metadata
if ! jq --exit-status '
      .status == "completed" and
      .conclusion == "success" and
      (.run_attempt | type == "number" and . >= 1 and . == floor)
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
