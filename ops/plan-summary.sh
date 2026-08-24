#!/bin/bash

# Classifies an OpenTofu JSON plan without printing resource values or addresses.
# Usage: ./ops/plan-summary.sh <bootstrap|foundation|release> <plan.json>

set -euo pipefail

if [ "$#" -ne 2 ]; then
    printf "Usage: %s <bootstrap|foundation|release> <plan.json>\n" "$0" >&2
    exit 64
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=ops/lib/roots.sh
. "${SCRIPT_DIR}/lib/roots.sh"

resolve_root "${REPOSITORY_ROOT}" "$1" >/dev/null

if [ ! -f "$2" ]; then
    printf "Plan JSON file not found.\n" >&2
    exit 66
fi

if ! jq -e 'type == "object" and (.resource_changes | type == "array")' "$2" >/dev/null; then
    printf "Plan JSON must contain a resource_changes array.\n" >&2
    exit 65
fi

# The JSON format may add actions in a backward-compatible minor release. A
# security gate must reject those until their semantics are reviewed explicitly.
if ! jq -e '
    def supported_actions:
        . == ["no-op"]
        or . == ["create"]
        or . == ["read"]
        or . == ["update"]
        or . == ["delete", "create"]
        or . == ["create", "delete"]
        or . == ["delete"]
        or . == ["forget"];

    all(.resource_changes[]; (.change.actions | supported_actions))
' "$2" >/dev/null; then
    printf "Plan contains an unsupported action combination.\n" >&2
    exit 65
fi

printf "action\tresource_type\tcount\n"
# OpenTofu includes unchanged resources as no-op changes. Omit them so a clean
# plan produces only the summary header.
jq -r '
    def classified_action:
        .change.actions as $actions
        | if (($actions | index("create")) != null and ($actions | index("delete")) != null) then "replace"
          elif (($actions | index("delete")) != null) then "delete"
          elif (($actions | index("create")) != null) then "create"
          elif (($actions | index("update")) != null) then "update"
          elif (($actions | index("read")) != null) then "read"
          elif (($actions | index("forget")) != null) then "forget"
          else "no-op"
          end;

    [.resource_changes[] | {type: .type, action: classified_action} | select(.action != "no-op")]
    | sort_by(.action, .type)
    | group_by([.action, .type])
    | .[]
    | "\(.[0].action)\t\(.[0].type)\t\(length)"
' "$2"

PROTECTED_CHANGES="$(jq -r '
    def protected_change:
        ((.change.actions | index("delete")) != null)
        or ((.change.actions | index("forget")) != null);

    def protected_type:
        . == "google_compute_disk"
        or . == "google_iam_workload_identity_pool"
        or . == "google_iam_workload_identity_pool_provider"
        or . == "google_project_iam_audit_config"
        or . == "google_project_iam_custom_role"
        or . == "google_project_iam_member"
        or . == "google_project"
        or . == "google_secret_manager_secret"
        or . == "google_secret_manager_secret_iam_member"
        or . == "google_service_account"
        or . == "google_service_account_iam_member"
        or . == "google_storage_bucket"
        or . == "google_storage_bucket_iam_member"
        or . == "google_storage_managed_folder"
        or . == "google_storage_managed_folder_iam_member";

    [.resource_changes[] | select(protected_change) | .type | select(protected_type)]
    | sort
    | group_by(.)
    | .[]
    | "\(.[0])\t\(length)"
' "$2")"

if [ -n "${PROTECTED_CHANGES}" ]; then
    while IFS=$'\t' read -r resource_type count; do
        printf "Protected resource deletion, replacement, or state forget: %s (%s).\n" "${resource_type}" "${count}" >&2
    done <<<"${PROTECTED_CHANGES}"
    exit 3
fi
