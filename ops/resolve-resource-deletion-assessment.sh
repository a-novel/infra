#!/bin/bash

# Proves that a human maintainer dispatched an assessment for the current PR tuple.
# Usage: resolve-resource-deletion-assessment.sh <owner/repository> <pr> <head-sha> <base-sha>

set -euo pipefail

if [ "$#" -ne 4 ]; then
    printf 'Usage: %s <owner/repository> <pr> <head-sha> <base-sha>\n' "$0" >&2
    exit 64
fi

REPOSITORY="$1"
PULL_REQUEST="$2"
HEAD_SHA="$3"
BASE_SHA="$4"
ACTOR="${GITHUB_ACTOR:-}"

if ! [[ "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    ! [[ "${PULL_REQUEST}" =~ ^[1-9][0-9]*$ ]] ||
    ! [[ "${HEAD_SHA}" =~ ^[a-f0-9]{40}$ ]] ||
    ! [[ "${BASE_SHA}" =~ ^[a-f0-9]{40}$ ]] ||
    ! [[ "${ACTOR}" =~ ^[A-Za-z0-9-]+$ ]] ||
    [ "${GITHUB_REF:-}" != refs/heads/master ] ||
    [ "${GITHUB_SHA:-}" != "${BASE_SHA}" ]; then
    printf 'The resource-deletion assessment request is invalid.\n' >&2
    exit 65
fi

for command_name in gh jq; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required by the trusted assessment workflow.\n' "${command_name}" >&2
        exit 69
    fi
done

if ! ACTOR_METADATA="$(gh api "users/${ACTOR}" 2>/dev/null)"; then
    printf 'Could not verify the assessment dispatcher identity.\n' >&2
    exit 70
fi
if ! jq --exit-status --arg actor "${ACTOR}" '
  .login == $actor and .type == "User"
' <<<"${ACTOR_METADATA}" >/dev/null; then
    printf 'A human maintainer must dispatch the resource-deletion assessment.\n' >&2
    exit 77
fi

if ! PERMISSION="$(gh api \
    "repos/${REPOSITORY}/collaborators/${ACTOR}/permission" \
    --jq .permission 2>/dev/null)"; then
    printf 'Could not verify the assessment dispatcher permission.\n' >&2
    exit 70
fi

case "${PERMISSION}" in
    admin | maintain | write) ;;
    *)
        printf 'A repository maintainer must dispatch the resource-deletion assessment.\n' >&2
        exit 77
        ;;
esac

if ! PR_METADATA="$(gh api "repos/${REPOSITORY}/pulls/${PULL_REQUEST}" 2>/dev/null)"; then
    printf 'Could not read the resource-deletion assessment target.\n' >&2
    exit 70
fi

if ! jq --exit-status \
    --arg repository "${REPOSITORY}" \
    --arg head "${HEAD_SHA}" \
    --arg base "${BASE_SHA}" '
      .state == "open" and
      .base.ref == "master" and
      .base.repo.full_name == $repository and
      .base.sha == $base and
      .head.sha == $head and
      (.head.repo.full_name | type) == "string" and
      (.head.repo.full_name | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
    ' <<<"${PR_METADATA}" >/dev/null; then
    printf 'The pull request no longer matches the requested head and base commits.\n' >&2
    exit 77
fi

jq --raw-output '.head.repo.full_name' <<<"${PR_METADATA}"
