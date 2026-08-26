#!/bin/bash

# Minimal OpenTofu protocol used to exercise the wrapper's exit-code mapping.

set -euo pipefail

if [[ "${1:-}" == -chdir=* ]]; then
    shift
fi

case "${1:-}" in
    init | fmt | validate | test)
        ;;
    apply)
        if [ -n "${FAKE_TOFU_REQUIRE_ABSENT:-}" ] &&
            [ -e "${FAKE_TOFU_REQUIRE_ABSENT}" ]; then
            printf 'Saved plan was still replayable when apply began.\n' >&2
            exit 77
        fi
        ;;
    plan)
        output=""
        for argument in "$@"; do
            if [[ "${argument}" == -out=* ]]; then
                output="${argument#-out=}"
            fi
        done
        if [ -z "${output}" ]; then
            exit 64
        fi
        : >"${output}"
        exit "${FAKE_TOFU_PLAN_CODE:?FAKE_TOFU_PLAN_CODE is required}"
        ;;
    show)
        command cat "${FAKE_TOFU_PLAN_JSON:?FAKE_TOFU_PLAN_JSON is required}"
        ;;
    *)
        exit 64
        ;;
esac
