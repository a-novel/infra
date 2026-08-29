#!/bin/bash

# Minimal OpenTofu protocol used to exercise the wrapper's exit-code mapping.

set -euo pipefail

if [[ "${1:-}" == -chdir=* ]]; then
    shift
fi

if [ "${FAKE_TOFU_FAIL_ACTION:-}" = "${1:-}" ] &&
    [ "${1:-}" != plan ] && [ "${1:-}" != apply ]; then
    printf 'fixture-sensitive-diagnostic\n' >&2
    exit 1
fi

case "${1:-}" in
    init | fmt | validate | test)
        ;;
    apply)
        event_file=""
        for argument in "$@"; do
            if [[ "${argument}" == -json-into=* ]]; then
                event_file="${argument#-json-into=}"
            fi
        done
        if [ -n "${FAKE_TOFU_REQUIRE_ABSENT:-}" ] &&
            [ -e "${FAKE_TOFU_REQUIRE_ABSENT}" ]; then
            printf 'Saved plan was still replayable when apply began.\n' >&2
            exit 77
        fi
        if [ "${FAKE_TOFU_FAIL_ACTION:-}" = apply ]; then
            if [ -n "${FAKE_TOFU_DIAGNOSTICS:-}" ] && [ -n "${event_file}" ]; then
                command cat "${FAKE_TOFU_DIAGNOSTICS}" >"${event_file}"
            fi
            printf 'fixture-sensitive-diagnostic\n' >&2
            exit 1
        fi
        ;;
    plan)
        output=""
        event_file=""
        for argument in "$@"; do
            if [[ "${argument}" == -out=* ]]; then
                output="${argument#-out=}"
            elif [[ "${argument}" == -json-into=* ]]; then
                event_file="${argument#-json-into=}"
            fi
        done
        if [ "${FAKE_TOFU_FAIL_ACTION:-}" = plan ]; then
            if [ -n "${FAKE_TOFU_DIAGNOSTICS:-}" ] && [ -n "${event_file}" ]; then
                command cat "${FAKE_TOFU_DIAGNOSTICS}" >"${event_file}"
            fi
            printf 'fixture-sensitive-diagnostic\n' >&2
            exit 1
        fi
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
