#!/bin/bash

# Prints the GitHub repository controls an operator checks before the first run.
# Usage: ./ops/verify-repository-gate.sh

set -euo pipefail

REPOSITORY='a-novel/infra'

gh auth status

RULESET_ID="$(gh api "repos/${REPOSITORY}/rulesets" \
    --jq '.[] | select(.name == "master") | .id')"

gh api "repos/${REPOSITORY}/rulesets/${RULESET_ID}" \
    --jq '{
      enforcement,
      required_status_checks: [
        .rules[]
        | select(.type == "required_status_checks")
        | .parameters.required_status_checks[].context
      ] | sort
    }'

gh variable list --repo "${REPOSITORY}" --json name,value \
    --jq '[.[] | select(.name == "PRODUCTION_RELEASES_ENABLED")]'
