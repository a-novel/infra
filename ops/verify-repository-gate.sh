#!/bin/bash

# Verifies the exact required-check source and intentionally narrow bypass policy.
# Usage: ./ops/verify-repository-gate.sh

set -euo pipefail

REPOSITORY='a-novel/infra'
ACTIONS_APP_ID=15368

for command_name in gh jq; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required to verify the repository gate.\n' "${command_name}" >&2
        exit 69
    fi
done

gh auth status

RULESET_ID="$(gh api "repos/${REPOSITORY}/rulesets" \
    --jq '.[] | select(.name == "master") | .id')"
if ! [[ "${RULESET_ID}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'The protected master ruleset is missing or ambiguous.\n' >&2
    exit 77
fi

RULESET="$(gh api "repos/${REPOSITORY}/rulesets/${RULESET_ID}")"
INSTALLATIONS="$(gh api --paginate 'orgs/a-novel/installations?per_page=100' \
    --jq '.installations[] | [.app_slug, .app_id] | @tsv')"

app_id() {
    local slug="$1"
    local matches
    matches="$(awk -F $'\t' -v slug="${slug}" '$1 == slug { print $2 }' <<<"${INSTALLATIONS}")"
    if ! [[ "${matches}" =~ ^[1-9][0-9]*$ ]]; then
        printf 'The %s GitHub App installation is missing or ambiguous.\n' "${slug}" >&2
        exit 77
    fi
    printf '%s\n' "${matches}"
}

DEPENDENCY_APP_ID="$(app_id anovelbot-dependencies)"
PUBLISH_APP_ID="$(app_id anovelbot-publish)"
AGENT_APP_ID="$(app_id anovelbot-agent)"

if ! jq --exit-status \
    --argjson actions_app "${ACTIONS_APP_ID}" \
    --argjson publish_app "${PUBLISH_APP_ID}" \
    --argjson agent_app "${AGENT_APP_ID}" '
      .enforcement == "active" and
      ([
        .rules[]
        | select(.type == "required_status_checks")
        | .parameters.required_status_checks[]
        | .context
      ] | sort) ==
      ([
        "epic-freeze",
        "lint-repository",
        "merge-gate",
        "resource-deletion-gate",
        "scan-infrastructure",
        "validate-opentofu"
      ] | sort) and
      any(
        .rules[]
        | select(.type == "required_status_checks")
        | .parameters.required_status_checks[];
        .context == "resource-deletion-gate" and .integration_id == $actions_app
      ) and
      ([
        .bypass_actors[]
        | {actor_id, actor_type, bypass_mode}
      ] | sort_by([.actor_type, (.actor_id // 0)])) ==
      ([
        {actor_id: null, actor_type: "OrganizationAdmin", bypass_mode: "always"},
        {actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"},
        {
          actor_id: $publish_app,
          actor_type: "Integration",
          bypass_mode: "always"
        },
        {
          actor_id: $agent_app,
          actor_type: "Integration",
          bypass_mode: "always"
        }
      ] | sort_by([.actor_type, (.actor_id // 0)]))
    ' <<<"${RULESET}" >/dev/null; then
    printf 'The master required checks, Actions source, or bypass policy is not reconciled.\n' >&2
    exit 77
fi

jq --argjson dependency_app "${DEPENDENCY_APP_ID}" '
  {
    enforcement,
    required_status_checks: [
      .rules[]
      | select(.type == "required_status_checks")
      | .parameters.required_status_checks[]
    ] | sort_by(.context),
    bypass_actors,
    dependency_bot_app_id: $dependency_app,
    dependency_bot_bypassed: any(
      .bypass_actors[];
      .actor_type == "Integration" and .actor_id == $dependency_app
    )
  }
' <<<"${RULESET}"

gh variable list --repo "${REPOSITORY}" --json name,value \
    --jq '[.[] | select(.name == "PRODUCTION_RELEASES_ENABLED")]'
