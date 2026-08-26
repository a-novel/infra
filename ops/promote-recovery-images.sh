#!/bin/bash

# Copy only receipt-owned immutable manifests into a disposable replacement
# registry. Tags are recovery-run scoped; digest equality is checked afterward.
# Usage: promote-recovery-images.sh <compiled-images.json>

set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s <compiled-images.json>\n' "$0" >&2
    exit 64
fi

IMAGES_FILE="$1"

manifest_digest() {
    docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>/dev/null \
        | jq --exit-status --raw-output '.digest' 2>/dev/null
}

if ! jq --exit-status '
    type == "array" and length == 8 and
    all(.[];
      (.source | test("@sha256:[a-f0-9]{64}$")) and
      (.target | test("@sha256:[a-f0-9]{64}$")) and
      (.tag | test(":recovery-[1-9][0-9]*$")) and
      (.digest | test("^sha256:[a-f0-9]{64}$"))
    )
  ' "${IMAGES_FILE}" >/dev/null; then
    printf 'Compiled recovery image inventory is invalid.\n' >&2
    exit 65
fi

while IFS=$'\t' read -r SOURCE TARGET TAG DIGEST; do
    if [ "$(manifest_digest "${SOURCE}" || true)" != "${DIGEST}" ]; then
        printf 'A receipt-owned source image is unavailable.\n' >&2
        exit 70
    fi
    EXISTING="$(manifest_digest "${TAG}" || true)"
    if [ -n "${EXISTING}" ] && [ "${EXISTING}" != "${DIGEST}" ]; then
        printf 'A recovery tag already identifies another digest.\n' >&2
        exit 70
    fi
    if [ -z "${EXISTING}" ]; then
        docker buildx imagetools create --tag "${TAG}" "${SOURCE}" >/dev/null 2>&1
    fi
    if [ "$(manifest_digest "${TAG}" || true)" != "${DIGEST}" ] ||
        [ "${TARGET##*@}" != "${DIGEST}" ]; then
        printf 'A recovery image copy changed its immutable digest.\n' >&2
        exit 70
    fi
done < <(jq --raw-output '.[] | [.source, .target, .tag, .digest] | @tsv' "${IMAGES_FILE}")

printf 'All receipt-owned images are present in the disposable recovery registry.\n'
