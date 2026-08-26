#!/bin/bash

# Copy verified OCI manifests into the immutable regional registry without
# rebuilding or retagging a local single-platform image. Docker Buildx is
# already present on GitHub-hosted runners, avoiding a second registry client.
# Usage: promote-release-images.sh <compiled-release.json> [receipt-run-id]

set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf 'Usage: %s <compiled-release.json> [receipt-run-id]\n' "$0" >&2
    exit 64
fi

RELEASE_FILE="$1"
RECEIPT_RUN_ID="${2:-}"

if [ -n "${RECEIPT_RUN_ID}" ] && ! [[ "${RECEIPT_RUN_ID}" =~ ^[1-9][0-9]*$ ]]; then
    printf 'Invalid receipt run ID.\n' >&2
    exit 65
fi

for command in docker jq; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        printf 'Required image promotion tooling is unavailable.\n' >&2
        exit 69
    fi
done

manifest_digest() {
    docker buildx imagetools inspect "$1" --format '{{json .Manifest}}' 2>/dev/null \
        | jq --exit-status --raw-output '.digest' 2>/dev/null
}

while IFS=$'\t' read -r SOURCE_DIGEST TARGET TARGET_TAG DIGEST; do
    EXISTING_DIGEST="$(manifest_digest "${TARGET_TAG}" || true)"
    if [ -n "${EXISTING_DIGEST}" ] && [ "${EXISTING_DIGEST}" != "${DIGEST}" ]; then
        printf 'An immutable production tag already identifies another digest.\n' >&2
        exit 70
    fi
    if [ -z "${EXISTING_DIGEST}" ]; then
        if ! docker buildx imagetools create \
            --tag "${TARGET_TAG}" \
            "${SOURCE_DIGEST}" >/dev/null 2>&1; then
            printf 'A verified image could not be promoted.\n' >&2
            exit 70
        fi
    fi
    if [ "$(manifest_digest "${TARGET_TAG}" || true)" != "${DIGEST}" ]; then
        printf 'A promoted image digest differs from its verified source.\n' >&2
        exit 70
    fi

    if [ -n "${RECEIPT_RUN_ID}" ]; then
        RECEIPT_TAG="${TARGET%@*}:receipt-${RECEIPT_RUN_ID}"
        RECEIPT_DIGEST="$(manifest_digest "${RECEIPT_TAG}" || true)"
        if [ -n "${RECEIPT_DIGEST}" ] && [ "${RECEIPT_DIGEST}" != "${DIGEST}" ]; then
            printf 'A receipt retention tag already identifies another digest.\n' >&2
            exit 70
        fi
        if [ -z "${RECEIPT_DIGEST}" ]; then
            docker buildx imagetools create \
                --tag "${RECEIPT_TAG}" \
                "${TARGET}" >/dev/null 2>&1
        fi
    fi
done < <(
    jq --raw-output '.images[] | [.sourceDigest, .promoted, .promotedTag, .digest] | @tsv' \
        "${RELEASE_FILE}"
)

if [ -n "${RECEIPT_RUN_ID}" ]; then
    printf 'Receipt retention tags created for all release images.\n'
else
    printf 'All verified images are present in the immutable production registry.\n'
fi
