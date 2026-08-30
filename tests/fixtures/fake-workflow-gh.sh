#!/bin/bash

# Provides deterministic GitHub workflow metadata for ops/run-workflow.sh tests.

set -euo pipefail

CALLS_FILE="${FAKE_WORKFLOW_CALLS:?FAKE_WORKFLOW_CALLS is required}"
STATE_FILE="${FAKE_WORKFLOW_STATE:?FAKE_WORKFLOW_STATE is required}"
WORKFLOW="${FAKE_WORKFLOW:-foundation.yaml}"
RUN_ID="${FAKE_WORKFLOW_RUN_ID:-202}"
RUN_ATTEMPT="${FAKE_WORKFLOW_RUN_ATTEMPT:-3}"
COMMIT="${FAKE_WORKFLOW_SHA:?FAKE_WORKFLOW_SHA is required}"

printf '%s\n' "$*" >>"${CALLS_FILE}"

case "${1:-}" in
    api)
        endpoint="${2:-}"
        case "${endpoint}" in
            repos/a-novel/infra/commits/master)
                printf '%s\n' "${FAKE_REMOTE_WORKFLOW_SHA:-${COMMIT}}"
                ;;
            'repos/a-novel/infra/actions/runs?branch=master&per_page=100')
                if [ "${FAKE_ACTIVE_WORKFLOW:-false}" = true ]; then
                    printf '303\tproduction foundation\tfoundation plan bootstrap\twaiting\thttps://github.com/a-novel/infra/actions/runs/303\n'
                fi
                ;;
            "repos/a-novel/infra/actions/runs/${RUN_ID}")
                jq -n \
                    --arg sha "${FAKE_PLAN_WORKFLOW_SHA:-${COMMIT}}" \
                    --arg path ".github/workflows/${FAKE_PLAN_WORKFLOW:-${WORKFLOW}}" \
                    --arg title "${FAKE_PLAN_DISPLAY_TITLE:-foundation plan foundation by @operator}" \
                    --argjson attempt "${RUN_ATTEMPT}" '
                      {
                        head_sha: $sha,
                        path: $path,
                        display_title: $title,
                        event: "workflow_dispatch",
                        status: "completed",
                        conclusion: "success",
                        run_attempt: $attempt
                      }
                    '
                ;;
            *) exit 64 ;;
        esac
        ;;
    workflow)
        [ "${2:-}" = run ]
        [ "${3:-}" = "${WORKFLOW}" ]
        touch "${STATE_FILE}"
        printf 'Created mock workflow dispatch.\n'
        ;;
    run)
        case "${2:-}" in
            list)
                if [[ "$*" == *'--json databaseId --jq [.[].databaseId]'* ]]; then
                    printf '[101]\n'
                elif [[ "$*" == *'--json databaseId,headSha,status,url'* ]]; then
                    if [ -f "${STATE_FILE}" ]; then
                        jq -n \
                            --arg sha "${COMMIT}" \
                            --argjson run_id "${RUN_ID}" '
                              [
                                {
                                  databaseId: $run_id,
                                  headSha: $sha,
                                  status: "queued",
                                  url: ("https://github.com/a-novel/infra/actions/runs/" + ($run_id | tostring))
                                },
                                {
                                  databaseId: 101,
                                  headSha: ("0" * 40),
                                  status: "completed",
                                  url: "https://github.com/a-novel/infra/actions/runs/101"
                                }
                              ]
                            '
                    else
                        printf '[]\n'
                    fi
                else
                    exit 64
                fi
                ;;
            watch)
                [ "${3:-}" = "${RUN_ID}" ]
                if [ "${FAKE_WORKFLOW_WATCH_FAILURE:-false}" = true ]; then
                    exit 1
                fi
                printf 'Mock workflow completed.\n'
                ;;
            *) exit 64 ;;
        esac
        ;;
    *) exit 64 ;;
esac
