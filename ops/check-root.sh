#!/bin/bash

# Validates one reviewed OpenTofu root without configuring a backend or cloud credentials.
# Usage: ./ops/check-root.sh <bootstrap|foundation|release>

set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf "Usage: %s <bootstrap|foundation|release>\n" "$0" >&2
    exit 64
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=ops/lib/roots.sh
. "${SCRIPT_DIR}/lib/roots.sh"

ROOT_DIR="$(resolve_root "${REPOSITORY_ROOT}" "$1")"

tofu -chdir="${ROOT_DIR}" fmt -check -diff
tofu -chdir="${ROOT_DIR}" init -backend=false -input=false -no-color
tofu -chdir="${ROOT_DIR}" validate -no-color
tofu -chdir="${ROOT_DIR}" test -no-color

tflint --init --config="${REPOSITORY_ROOT}/.tflint.hcl"
tflint --chdir="${ROOT_DIR}" --config="${REPOSITORY_ROOT}/.tflint.hcl" --format=compact
