#!/bin/bash

# Provides deterministic GitHub metadata and verdict downloads for deletion-gate tests.

set -euo pipefail

HEAD_SHA="${FAKE_GATE_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
BASE_SHA="${FAKE_GATE_BASE:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
PULL_REQUEST="${FAKE_GATE_PR:-93}"
HEAD_REPOSITORY="${FAKE_GATE_HEAD_REPOSITORY:-a-novel/infra}"
LABEL_MODE="${FAKE_GATE_LABEL_MODE:-missing}"

if [ -n "${FAKE_GATE_CALLS:-}" ]; then
    printf '%s\n' "$*" >>"${FAKE_GATE_CALLS}"
fi

pull_request_json() {
    local labels='[]'
    if [ "${LABEL_MODE}" = approved ] || [ "${LABEL_MODE}" = bot ] ||
        [ "${LABEL_MODE}" = untrusted ]; then
        labels='[{"name":"allow-resource-deletion"}]'
    fi
    jq -n \
        --argjson number "${PULL_REQUEST}" \
        --arg head "${HEAD_SHA}" \
        --arg base "${BASE_SHA}" \
        --arg head_repository "${HEAD_REPOSITORY}" \
        --argjson labels "${labels}" '
          {
            number: $number,
            state: "open",
            labels: $labels,
            base: {
              ref: "master",
              sha: $base,
              repo: {full_name: "a-novel/infra"}
            },
            head: {
              sha: $head,
              repo: {full_name: $head_repository}
            }
          }
        '
}

if [ "${1:-}" = api ]; then
    shift
    endpoint=''
    slurp=false
    query=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -H)
                shift 2
                ;;
            --jq)
                query="$2"
                shift 2
                ;;
            --slurp)
                slurp=true
                shift
                ;;
            --paginate)
                shift
                ;;
            repos/* | users/* | orgs/*)
                endpoint="$1"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    if [ "${slurp}" = true ] && [ -n "${query}" ]; then
        printf 'The --slurp option is not supported with --jq.\n' >&2
        exit 1
    fi

    case "${endpoint}" in
        users/*)
            actor="${endpoint#users/}"
            jq -n --arg actor "${actor}" --arg type "${FAKE_GATE_ACTOR_TYPE:-User}" \
                '{login: $actor, type: $type}'
            ;;
        "repos/a-novel/infra/pulls/${PULL_REQUEST}")
            pull_request_json
            ;;
        repos/a-novel/infra/commits/*/pulls)
            pull_request_json | jq '[.]'
            ;;
        "repos/a-novel/infra/pulls/${PULL_REQUEST}/files?per_page=100")
            [ "${slurp}" = true ]
            if [ "${FAKE_GATE_FILES:-image}" = failed ]; then
                printf '%s\n' '[]'
                exit 1
            fi
            case "${FAKE_GATE_FILES:-image}" in
                docs) jq -n '[{filename: "README.md"}]' ;;
                foundation) jq -n '[{filename: "environments/production/foundation/main.tf"}]' ;;
                release) jq -n '[{filename: "environments/production/release/main.tf"}]' ;;
                image) jq -n '[{filename: "deploy/production/images.yaml"}]' ;;
                shared) jq -n '[{filename: "modules/shared/main.tf"}]' ;;
                *) exit 64 ;;
            esac | jq '[[], .]'
            ;;
        'repos/a-novel/infra/actions/workflows/drift.yaml/runs?branch=master&event=workflow_dispatch&per_page=100')
            if [ "${FAKE_GATE_RUN_MODE:-success}" = no-run ]; then
                printf '%s\n' '[{"workflow_runs":[]}]'
            else
                conclusion=success
                if [ "${FAKE_GATE_RUN_MODE:-success}" = failed ]; then
                    conclusion=failure
                fi
                jq -n \
                    --arg title "resource-deletion assessment PR #${PULL_REQUEST} ${HEAD_SHA} onto ${BASE_SHA}" \
                    --arg base "${BASE_SHA}" \
                    --arg conclusion "${conclusion}" '
                      [{
                        workflow_runs: [{
                          id: 404,
                          display_title: $title,
                          path: ".github/workflows/drift.yaml",
                          event: "workflow_dispatch",
                          head_branch: "master",
                          head_sha: $base,
                          status: "completed",
                          conclusion: $conclusion,
                          run_attempt: 2
                        }]
                      }]
                    '
            fi
            ;;
        repos/a-novel/infra/actions/runs/404/artifacts?per_page=100)
            if [ "${FAKE_GATE_ARTIFACT_MISSING:-false}" = true ]; then
                printf '%s\n' '{"artifacts":[]}'
            else
                printf '%s\n' '{"artifacts":[{"id":505,"name":"resource-deletion-assessment-2","expired":false}]}'
            fi
            ;;
        "repos/a-novel/infra/issues/${PULL_REQUEST}/timeline")
            case "${LABEL_MODE}" in
                approved)
                    actor_type=User
                    actor=maintainer
                    via_app=null
                    ;;
                bot)
                    actor_type=Bot
                    actor=automation-bot
                    via_app='{"id":123}'
                    ;;
                untrusted)
                    actor_type=User
                    actor=viewer
                    via_app=null
                    ;;
                *)
                    printf '%s\n' '[[]]'
                    exit 0
                    ;;
            esac
            jq -n \
                --arg actor "${actor}" \
                --arg actor_type "${actor_type}" \
                --argjson via_app "${via_app}" '
                  [[{
                    event: "labeled",
                    id: 1,
                    created_at: "2026-09-06T01:00:00Z",
                    label: {name: "allow-resource-deletion"},
                    actor: {login: $actor, type: $actor_type},
                    performed_via_github_app: $via_app
                  }]]
                '
            ;;
        repos/a-novel/infra/collaborators/*/permission)
            printf '%s\n' "${FAKE_GATE_PERMISSION:-admin}"
            ;;
        *)
            printf 'Unsupported fake GitHub endpoint: %s\n' "${endpoint}" >&2
            exit 64
            ;;
    esac
elif [ "${1:-} ${2:-}" = 'run download' ]; then
    shift 2
    [ "${1:-}" = 404 ]
    shift
    directory=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dir)
                directory="$2"
                shift 2
                ;;
            --repo | --name)
                shift 2
                ;;
            *)
                exit 64
                ;;
        esac
    done
    [ -n "${directory}" ]
    mkdir -p -- "${directory}"
    cp -- "${FAKE_GATE_ASSESSMENT_FILE:?}" "${directory}/assessment.json"
else
    exit 64
fi
