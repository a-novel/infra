#!/bin/bash

# Runs the only supported live OpenTofu plan/apply paths and never prints plan
# values. Detailed plan codes remain 0 (clean), 1 (error), and 2 (changes).
# Usage: tofu-gate.sh <plan|apply|converge|drift|output> <bootstrap|foundation|release> <state-bucket> [private-file]

set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    printf 'Usage: %s <plan|apply|converge|drift|output> <bootstrap|foundation|release> <state-bucket> [private-file]\n' "$0" >&2
    exit 64
fi

ACTION="$1"
ROOT_NAME="$2"
STATE_BUCKET="$3"
PLAN_FILE="${4:-}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=ops/lib/roots.sh
. "${SCRIPT_DIR}/lib/roots.sh"

ROOT_DIR="$(resolve_root "${REPOSITORY_ROOT}" "${ROOT_NAME}")"

case "${ACTION}" in
    plan | apply | output)
        if [ -z "${PLAN_FILE}" ]; then
            printf 'A private plan file is required for %s.\n' "${ACTION}" >&2
            exit 64
        fi
        ;;
    converge | drift)
        if [ -n "${PLAN_FILE}" ]; then
            printf '%s does not accept a plan file.\n' "${ACTION}" >&2
            exit 64
        fi
        ;;
    *)
        printf 'Unknown action. Expected plan, apply, converge, drift, or output.\n' >&2
        exit 64
        ;;
esac

if ! [[ "${STATE_BUCKET}" =~ ^[a-z0-9][a-z0-9._-]{1,221}[a-z0-9]$ ]]; then
    printf 'Invalid state bucket name.\n' >&2
    exit 65
fi

STATE_PREFIX="${ROOT_NAME}"
if [ -n "${TOFU_STATE_SUFFIX:-}" ]; then
    if ! [[ "${TOFU_STATE_SUFFIX}" =~ ^recovery/[a-z0-9][a-z0-9-]{0,62}$ ]]; then
        printf 'Invalid recovery state suffix.\n' >&2
        exit 65
    fi
    STATE_PREFIX="${ROOT_NAME}/${TOFU_STATE_SUFFIX}"
fi

if [ -n "${TOFU_VAR_FILE:-}" ] && [ ! -f "${TOFU_VAR_FILE}" ]; then
    printf 'The private OpenTofu variable file does not exist.\n' >&2
    exit 66
fi

for command_name in git jq tofu; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        printf '%s is required by the protected OpenTofu environment.\n' "${command_name}" >&2
        exit 69
    fi
done

# Authentication helpers may create ignored credential files, but every
# non-ignored file must still be represented by the checked-out commit.
if [ -n "$(git -C "${REPOSITORY_ROOT}" status --porcelain)" ]; then
    printf 'The repository differs from the exact checked-out commit.\n' >&2
    exit 65
fi

TEMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf -- "${TEMP_DIR}"
}
trap cleanup INT TERM EXIT

if [ -z "${TF_DATA_DIR:-}" ]; then
    export TF_DATA_DIR="${TEMP_DIR}/tofu-data"
fi

VAR_ARGS=()
if [ -n "${TOFU_VAR_FILE:-}" ]; then
    VAR_ARGS+=("-var-file=${TOFU_VAR_FILE}")
fi

run_quietly() {
    local diagnostic_file="$1"
    local stage="$2"
    shift 2

    if ! "$@" >"${diagnostic_file}" 2>&1; then
        printf 'Protected OpenTofu %s failed; its potentially sensitive diagnostics were not published.\n' "${stage}" >&2
        return 1
    fi
}

initialize_root() {
    run_quietly "${TEMP_DIR}/init.log" "backend initialization" \
        tofu -chdir="${ROOT_DIR}" init \
        -reconfigure \
        -input=false \
        -no-color \
        -backend-config="bucket=${STATE_BUCKET}" \
        -backend-config="prefix=${STATE_PREFIX}"
}

validate_root() {
    run_quietly "${TEMP_DIR}/fmt.log" "format check" tofu -chdir="${ROOT_DIR}" fmt -check -diff
    run_quietly "${TEMP_DIR}/validate.log" validation tofu -chdir="${ROOT_DIR}" validate -no-color
    run_quietly "${TEMP_DIR}/test.log" tests tofu -chdir="${ROOT_DIR}" test -no-color
}

classify_plan() {
    local binary_plan="$1"
    local json_plan="${TEMP_DIR}/plan.json"
    local summary_code=0

    if ! tofu -chdir="${ROOT_DIR}" show -json "${binary_plan}" \
        >"${json_plan}" 2>"${TEMP_DIR}/show.log"; then
        printf 'OpenTofu could not decode the private saved plan.\n' >&2
        return 1
    fi

    if "${SCRIPT_DIR}/plan-summary.sh" "${ROOT_NAME}" "${json_plan}"; then
        summary_code=0
    else
        summary_code=$?
    fi

    case "${summary_code}" in
        0)
            return 0
            ;;
        3)
            if [ "${ALLOW_RESOURCE_DELETION:-false}" = 'true' ]; then
                printf 'Managed-resource deletion is covered by the protected approval recorded for this commit.\n'
                return 0
            fi
            return 3
            ;;
        *)
            return "${summary_code}"
            ;;
    esac
}

summarize_plan_failure() {
    local event_file="$1"
    local summary_file="${TEMP_DIR}/plan-diagnostics.tsv"

    if [ ! -s "${event_file}" ]; then
        printf 'Sanitized plan diagnostics were unavailable.\n' >&2
        return
    fi

    # Raw diagnostic text may contain configuration values. The public summary
    # is built only from fixed reasons and strictly filtered source metadata.
    if ! jq --raw-output --slurp '
        def diagnostic_text:
            [.diagnostic.summary?, .diagnostic.detail?]
            | map(select(type == "string"))
            | join("\n");

        def diagnostic_reason:
            diagnostic_text as $text
            | (.diagnostic.summary? // "") as $summary
            | if ($text | test("ZONE_RESOURCE_POOL_EXHAUSTED"; "i")) then "ZONE_RESOURCE_POOL_EXHAUSTED"
              elif ($text | test("RESOURCE_EXHAUSTED|quota (has been )?(reached|exceeded)|rate limit"; "i")) then "RESOURCE_EXHAUSTED"
              elif ($text | test("PERMISSION_DENIED|permission denied|forbidden|error:? +403|status( code)?[ :=]+403|code[ :=]+403"; "i")) then "PERMISSION_DENIED"
              elif ($text | test("UNAUTHENTICATED|error:? +401|status( code)?[ :=]+401|code[ :=]+401|default credentials"; "i")) then "UNAUTHENTICATED"
              elif ($text | test("NOT_FOUND|not found|does not exist|error:? +404|status( code)?[ :=]+404|code[ :=]+404"; "i")) then "NOT_FOUND"
              elif ($text | test("INVALID_ARGUMENT|error:? +400|status( code)?[ :=]+400|code[ :=]+400"; "i")) then "INVALID_ARGUMENT"
              elif ($text | test("FAILED_PRECONDITION|state lock|state is locked"; "i")) then "FAILED_PRECONDITION"
              elif ($text | test("ALREADY_EXISTS|error:? +409|status( code)?[ :=]+409|code[ :=]+409"; "i")) then "ALREADY_EXISTS"
              elif ($text | test("ABORTED|concurrent policy changes"; "i")) then "ABORTED"
              elif ($text | test("DEADLINE_EXCEEDED|error:? +504|status( code)?[ :=]+504|code[ :=]+504"; "i")) then "DEADLINE_EXCEEDED"
              elif ($text | test("UNAVAILABLE|error:? +503|status( code)?[ :=]+503|code[ :=]+503"; "i")) then "UNAVAILABLE"
              elif ($text | test("INTERNAL|error:? +500|status( code)?[ :=]+500|code[ :=]+500"; "i")) then "INTERNAL"
              elif ($summary | test("^(Invalid|Unsupported|Missing required|Reference to undeclared|Error in function call|Inconsistent|Resource precondition failed|Module not installed|Provider configuration not present)"; "i")) then "CONFIGURATION"
              else "UNKNOWN"
              end;

        def diagnostic_resource_type:
            (.diagnostic.snippet.context? // "") as $context
            | if ($context | type) == "string" then
                (($context | capture("^(data|resource) \"(?<type>google_[a-z0-9_]+)\"")?.type) // "-")
              else "-"
              end;

        def diagnostic_source:
            (.diagnostic.range? // {}) as $range
            | ($range.filename? // "") as $raw_filename
            | (if ($raw_filename | type) == "string" then
                 ($raw_filename | gsub("\\\\"; "/") | split("/") | last)
               else ""
               end) as $filename
            | ($range.start.line? // 0) as $line
            | if ($filename | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))
                 and (($line | type) == "number")
                 and ($line >= 1)
                 and ($line == ($line | floor)) then
                "\($filename):\($line)"
              else "-"
              end;

        [
          .[]
          | select(.type == "diagnostic" and .diagnostic.severity == "error")
          | {
              reason: diagnostic_reason,
              resource_type: diagnostic_resource_type,
              source: diagnostic_source
            }
        ]
        | sort_by(.reason, .resource_type, .source)
        | group_by([.reason, .resource_type, .source])
        | .[]
        | [.[0].reason, .[0].resource_type, .[0].source, (length | tostring)]
        | @tsv
    ' "${event_file}" >"${summary_file}" 2>"${TEMP_DIR}/plan-diagnostics.log"; then
        printf 'Sanitized plan diagnostics were unavailable.\n' >&2
        return
    fi

    if [ ! -s "${summary_file}" ]; then
        printf 'Sanitized plan diagnostics were unavailable.\n' >&2
        return
    fi

    printf 'reason\tresource_type\tsource\tcount\n' >&2
    command cat "${summary_file}" >&2
}

plan_changes() {
    local output_plan="$1"
    local lock_flag="$2"
    local event_file="${TEMP_DIR}/plan-events.jsonl"
    local plan_code=0
    local summary_code=0

    if tofu -chdir="${ROOT_DIR}" plan \
        -detailed-exitcode \
        -input=false \
        -json-into="${event_file}" \
        -lock="${lock_flag}" \
        -no-color \
        -out="${output_plan}" \
        "${VAR_ARGS[@]}" \
        >"${TEMP_DIR}/plan.log" 2>&1; then
        plan_code=0
    else
        plan_code=$?
    fi

    case "${plan_code}" in
        0 | 2)
            if classify_plan "${output_plan}"; then
                summary_code=0
            else
                summary_code=$?
                return "${summary_code}"
            fi
            return "${plan_code}"
            ;;
        1)
            printf 'OpenTofu planning failed; its potentially sensitive diagnostics were not published.\n' >&2
            summarize_plan_failure "${event_file}"
            return 1
            ;;
        *)
            printf 'OpenTofu returned an unsupported detailed plan code.\n' >&2
            return 70
            ;;
    esac
}

initialize_root

case "${ACTION}" in
    plan)
        validate_root
        plan_changes "${PLAN_FILE}" true
        ;;
    apply)
        if [ ! -f "${PLAN_FILE}" ]; then
            printf 'The exact reviewed plan file does not exist.\n' >&2
            exit 66
        fi
        run_quietly "${TEMP_DIR}/apply.log" apply \
            tofu -chdir="${ROOT_DIR}" apply -input=false -no-color "${PLAN_FILE}"
        printf 'The exact reviewed %s plan applied successfully.\n' "${ROOT_NAME}"
        ;;
    output)
        if ! tofu -chdir="${ROOT_DIR}" output -json \
            >"${PLAN_FILE}" 2>"${TEMP_DIR}/output.log"; then
            printf 'Protected OpenTofu outputs could not be read.\n' >&2
            exit 70
        fi
        chmod 600 "${PLAN_FILE}"
        ;;
    converge | drift)
        if [ "${ACTION}" = 'converge' ]; then
            LOCK_FLAG=true
        else
            LOCK_FLAG=false
        fi

        PLAN_CODE=0
        if plan_changes "${TEMP_DIR}/${ACTION}.tfplan" "${LOCK_FLAG}"; then
            PLAN_CODE=0
        else
            PLAN_CODE=$?
        fi

        if [ "${PLAN_CODE}" -eq 0 ]; then
            printf '%s is converged.\n' "${ROOT_NAME}"
        elif [ "${PLAN_CODE}" -eq 2 ] || [ "${PLAN_CODE}" -eq 3 ]; then
            printf '%s has drift; dependent mutations remain blocked.\n' "${ROOT_NAME}" >&2
            exit 2
        else
            exit "${PLAN_CODE}"
        fi
        ;;
esac
