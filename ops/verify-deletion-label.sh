#!/bin/bash

# Verifies that the exact checked-out merge commit came from a PR carrying the
# deliberate resource-deletion label at merge time, added by a maintainer. It
# prints no PR body, diff, event history, actor, or labels.
# Usage: verify-deletion-label.sh <owner/repository> <40-character-commit>

set -euo pipefail

if [ "$#" -ne 2 ]; then
    printf 'Usage: %s <owner/repository> <40-character-commit>\n' "$0" >&2
    exit 64
fi

REPOSITORY="$1"
COMMIT="$2"
REQUIRED_LABEL='allow-resource-deletion'

if ! [[ "${REPOSITORY}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    ! [[ "${COMMIT}" =~ ^[a-f0-9]{40}$ ]]; then
    printf 'Invalid repository or commit.\n' >&2
    exit 65
fi

for command_name in gh jq; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required by the protected approval environment.\n' "${command_name}" >&2
        exit 69
    fi
done

if ! PULL_REQUESTS="$(gh api \
    -H 'Accept: application/vnd.github+json' \
    "repos/${REPOSITORY}/commits/${COMMIT}/pulls" 2>/dev/null)"; then
    printf 'Could not verify the resource-deletion approval.\n' >&2
    exit 70
fi

if ! PR_NUMBER="$(jq --exit-status --raw-output \
    --arg commit "${COMMIT}" '
        [
          .[]
          | select(.merged_at != null)
          | select(.merge_commit_sha == $commit)
          | .number
        ]
        | if length == 1 then .[0] else error("merge missing or ambiguous") end
    ' <<<"${PULL_REQUESTS}" 2>/dev/null)"; then
    printf 'Managed-resource deletion requires one merged PR for the exact commit.\n' >&2
    exit 77
fi

if ! TIMELINE="$(gh api --paginate --slurp \
    -H 'Accept: application/vnd.github+json' \
    "repos/${REPOSITORY}/issues/${PR_NUMBER}/timeline" 2>/dev/null)"; then
    printf 'Could not verify the historical resource-deletion approval.\n' >&2
    exit 70
fi

# Replaying events only until the merge prevents a label added afterward from
# retroactively authorizing deletion. A later removal does not erase the
# approval that was deliberately present at the reviewed merge gate.
if ! APPROVER="$(jq --exit-status --raw-output \
    --arg label "${REQUIRED_LABEL}" '
      reduce (
        flatten
        | sort_by(.created_at, .id)
        | .[]
      ) as $event (
        {merged: false, approved: false, approver: null};
        if .merged then .
        elif $event.event == "labeled" and $event.label.name == $label then
          .approved = true | .approver = $event.actor.login
        elif $event.event == "unlabeled" and $event.label.name == $label then
          .approved = false | .approver = null
        elif $event.event == "merged" then
          .merged = true
        else . end
      )
      | select(.merged and .approved and (.approver | type == "string"))
      | .approver
    ' <<<"${TIMELINE}" 2>/dev/null)"; then
    printf 'Managed-resource deletion requires the %s label to be present when the exact PR merges.\n' "${REQUIRED_LABEL}" >&2
    exit 77
fi

if ! PERMISSION="$(gh api \
    -H 'Accept: application/vnd.github+json' \
    "repos/${REPOSITORY}/collaborators/${APPROVER}/permission" \
    --jq .permission 2>/dev/null)"; then
    printf 'Could not verify that the resource-deletion approver is a maintainer.\n' >&2
    exit 70
fi

case "${PERMISSION}" in
    admin | maintain | write) ;;
    *)
        printf 'The resource-deletion label must be added by a repository maintainer before merge.\n' >&2
        exit 77
        ;;
esac

printf 'Resource-deletion approval verified on PR #%s.\n' "${PR_NUMBER}"
