#!/bin/bash

# Verifies the fixed repository, checked-out master commit, required checks,
# GitHub authentication, and disabled production release switch before first use.
# Usage: ./ops/verify-repository-gate.sh

set -euo pipefail
set +x
umask 077

if [ "$#" -ne 0 ]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 64
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPOSITORY='a-novel/infra'
EXPECTED_CHECKS=$'epic-freeze\nlint-repository\nmerge-gate\nscan-infrastructure\nvalidate-opentofu'

for command_name in git gh; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required to verify the repository gate.\n' "${command_name}" >&2
        exit 69
    fi
done

cd -- "${REPOSITORY_ROOT}"
if [ -n "$(git status --porcelain)" ]; then
    printf 'STOP: the infrastructure checkout is not clean.\n' >&2
    exit 77
fi

if [ "$(git branch --show-current)" != master ]; then
    printf 'STOP: the infrastructure checkout is not on master.\n' >&2
    exit 77
fi

LOCAL_COMMIT="$(git rev-parse HEAD)"
if ! [[ "${LOCAL_COMMIT}" =~ ^[a-f0-9]{40}$ ]]; then
    printf 'Could not resolve the checked-out commit.\n' >&2
    exit 70
fi

gh auth status

if ! REMOTE_COMMIT="$(gh api "repos/${REPOSITORY}/commits/master" --jq .sha)"; then
    printf 'Could not resolve the remote master commit.\n' >&2
    exit 70
fi
if [ "${LOCAL_COMMIT}" != "${REMOTE_COMMIT}" ]; then
    printf 'STOP: the checkout is not at the remote master commit.\n' >&2
    exit 77
fi

if ! RULESET_ID="$(gh api "repos/${REPOSITORY}/rulesets" \
    --jq '.[] | select(.name == "master") | .id')"; then
    printf 'Could not resolve the master ruleset.\n' >&2
    exit 70
fi
if ! [[ "${RULESET_ID}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'STOP: expected exactly one numeric master ruleset ID.\n' >&2
    exit 77
fi

if ! RULESET_ENFORCEMENT="$(gh api "repos/${REPOSITORY}/rulesets/${RULESET_ID}" \
    --jq .enforcement)"; then
    printf 'Could not resolve the master ruleset enforcement mode.\n' >&2
    exit 70
fi
if [ "${RULESET_ENFORCEMENT}" != active ]; then
    printf 'STOP: the master ruleset is not actively enforced.\n' >&2
    exit 77
fi

if ! ACTUAL_CHECKS="$(gh api "repos/${REPOSITORY}/rulesets/${RULESET_ID}" \
    --jq '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | sort | .[]')"; then
    printf 'Could not resolve the required status checks.\n' >&2
    exit 70
fi
if [ "${ACTUAL_CHECKS}" != "${EXPECTED_CHECKS}" ]; then
    printf 'STOP: the master ruleset required-check list differs from repository policy.\n' >&2
    printf 'Expected:\n%s\nActual:\n%s\n' "${EXPECTED_CHECKS}" "${ACTUAL_CHECKS:-<none>}" >&2
    exit 77
fi

if ! RELEASE_SWITCH="$(gh variable list --repo "${REPOSITORY}" --json name,value \
    --jq '.[] | select(.name == "PRODUCTION_RELEASES_ENABLED") | .value')"; then
    printf 'Could not resolve the production release switch.\n' >&2
    exit 70
fi
case "${RELEASE_SWITCH}" in
    false) ;;
    '')
        printf 'Release switch is not created yet; bootstrap will create it as false.\n'
        ;;
    *)
        printf 'STOP: PRODUCTION_RELEASES_ENABLED must be false or absent before bootstrap.\n' >&2
        exit 77
        ;;
esac

printf 'Repository gate passed for %s at %s.\n' "${REPOSITORY}" "${LOCAL_COMMIT}"
