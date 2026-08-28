#!/bin/bash

# Reads one runbook value for capture by command substitution.
# Usage: ./ops/prompt.sh [--secret] <prompt>

set -euo pipefail
set +x

SECRET=false
if [ "${1:-}" = --secret ]; then
    SECRET=true
    shift
fi

if [ "$#" -ne 1 ]; then
    printf "Usage: %s [--secret] <prompt>\n" "$0" >&2
    exit 64
fi

if [ "${SECRET}" = true ] && [ -t 1 ]; then
    printf "Capture secret input with command substitution.\n" >&2
    exit 64
fi

printf '%s' "$1" >&2
if [ "${SECRET}" = true ]; then
    if ! IFS= read -r -s VALUE; then
        printf '\nInput ended before a value was read.\n' >&2
        exit 1
    fi
    printf '\n' >&2
elif ! IFS= read -r VALUE; then
    printf 'Input ended before a value was read.\n' >&2
    exit 1
fi

printf '%s' "${VALUE}"
