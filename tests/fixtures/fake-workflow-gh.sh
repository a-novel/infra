#!/bin/bash

# Provides deterministic GitHub workflow metadata for ops/run-workflow.sh tests.

set -euo pipefail

CALLS_FILE="${FAKE_WORKFLOW_CALLS:?FAKE_WORKFLOW_CALLS is required}"
WORKFLOW="${FAKE_WORKFLOW:-foundation.yaml}"
RUN_ID="${FAKE_WORKFLOW_RUN_ID:-202}"
RUN_ATTEMPT="${FAKE_WORKFLOW_RUN_ATTEMPT:-3}"
COMMIT="${FAKE_WORKFLOW_SHA:?FAKE_WORKFLOW_SHA is required}"

jq --compact-output --null-input --args '$ARGS.positional' -- "$@" >>"${CALLS_FILE}"

case "${1:-}" in
    api)
        endpoint="${2:-}"
        case "${endpoint}" in
            repos/a-novel/infra/commits/master)
                printf '%s\n' "${FAKE_REMOTE_WORKFLOW_SHA:-${COMMIT}}"
                ;;
            "repos/a-novel/infra/pulls/${FAKE_ASSESSMENT_PR:-93}")
                jq -n \
                    --arg sha "${FAKE_ASSESSMENT_HEAD:-$(printf 'a%.0s' {1..40})}" \
                    --arg base "${FAKE_REMOTE_WORKFLOW_SHA:-${COMMIT}}" '
                      {
                        state: "open",
                        base: {
                          ref: "master",
                          sha: $base,
                          repo: {full_name: "a-novel/infra"}
                        },
                        head: {sha: $sha}
                      }
                    '
                ;;
            'repos/a-novel/infra/actions/runs?branch=master&per_page=100')
                if [ "${FAKE_ACTIVE_WORKFLOW:-false}" = true ]; then
                    printf '303\tproduction foundation\tfoundation plan bootstrap\twaiting\thttps://github.com/a-novel/infra/actions/runs/303\n'
                fi
                ;;
            "repos/a-novel/infra/actions/workflows/${WORKFLOW}/dispatches")
                if [ "${FAKE_DISPATCH_FAILURE:-false}" = true ]; then exit 1; fi
                if [ "${FAKE_DISPATCH_RESPONSE+x}" ]; then
                    printf '%s\n' "${FAKE_DISPATCH_RESPONSE}"
                else
                    jq -n --argjson id "${RUN_ID}" '{
                      workflow_run_id: $id,
                      run_url: ("https://api.github.com/repos/a-novel/infra/actions/runs/" + ($id | tostring)),
                      html_url: ("https://github.com/a-novel/infra/actions/runs/" + ($id | tostring))
                    }'
                fi
                ;;
            "repos/a-novel/infra/actions/runs/${RUN_ID}" | repos/a-novel/infra/actions/runs/101)
                override='{}'
                if [ "${endpoint##*/}" = 101 ]; then
                    override="${FAKE_PLAN_OVERRIDE:-${override}}"
                elif [ "${FAKE_RUN_READ_FAILURE:-false}" = true ]; then
                    exit 1
                else
                    override="${FAKE_RUN_OVERRIDE:-${override}}"
                fi
                jq -n \
                    --arg sha "${COMMIT}" \
                    --arg path ".github/workflows/${WORKFLOW}" \
                    --argjson id "${endpoint##*/}" \
                    --argjson override "${override}" \
                    --argjson attempt "${RUN_ATTEMPT}" '
                      {
                        id: $id,
                        head_sha: $sha,
                        head_branch: "master",
                        path: $path,
                        display_title: "foundation plan foundation by @operator",
                        event: "workflow_dispatch",
                        status: "completed",
                        conclusion: "success",
                        run_attempt: $attempt
                      } + $override
                    '
                ;;
            *) exit 64 ;;
        esac
        ;;
    run)
        case "${2:-}" in
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
