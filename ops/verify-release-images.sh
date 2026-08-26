#!/bin/bash

# Verify every public source image before Google credentials are minted. The
# checked digest, repository, SemVer family, producer attestation, and database
# PostgreSQL major are the only inputs accepted by later promotion.
# Usage: verify-release-images.sh <compiled-release.json>

set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s <compiled-release.json>\n' "$0" >&2
    exit 64
fi

RELEASE_FILE="$1"

for command in docker gh jq; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        printf 'Required release verification tooling is unavailable.\n' >&2
        exit 69
    fi
done

if ! jq --exit-status '
    .schemaVersion == 1 and
    (.postgresMajor == 18) and
    (.images | length == 8) and
    ([.images[].sourceDigest] | length == (unique | length)) and
    all(.images[];
      (.component == "service-json-keys" or .component == "service-authentication") and
      (.source == (.repository + ":" + .tag)) and
      (.sourceDigest == (.repository + "@" + .digest)) and
      (.tag | test("^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$")) and
      (.digest | test("^sha256:[a-f0-9]{64}$"))
    )
' "${RELEASE_FILE}" >/dev/null; then
    printf 'Compiled release image inventory is invalid.\n' >&2
    exit 65
fi

while IFS=$'\t' read -r COMPONENT SLOT SOURCE SOURCE_DIGEST; do
    REPOSITORY="a-novel/${COMPONENT}"
    if ! gh attestation verify "oci://${SOURCE_DIGEST}" \
        --repo "${REPOSITORY}" >/dev/null 2>&1; then
        printf 'A release image lacks a valid producer attestation.\n' >&2
        exit 70
    fi

    if ! docker pull "${SOURCE}" >/dev/null 2>&1; then
        printf 'A release image could not be pulled by immutable tag.\n' >&2
        exit 70
    fi
    if ! docker image inspect "${SOURCE}" \
        --format '{{json .RepoDigests}}' \
        2>/dev/null \
        | jq --exit-status --arg expected "${SOURCE_DIGEST}" \
            'index($expected) != null' >/dev/null; then
        printf 'A release image tag does not resolve to its reviewed digest.\n' >&2
        exit 70
    fi

    if [ "${SLOT}" = "database" ]; then
        if ! docker image inspect "${SOURCE}" \
            --format '{{json .Config.Env}}' \
            2>/dev/null \
            | jq --exit-status --arg major "PG_MAJOR=18" \
                'index($major) != null' >/dev/null; then
            printf 'A database image does not declare the reviewed PostgreSQL major.\n' >&2
            exit 70
        fi
    fi
done < <(
    jq --raw-output '.images[] | [.component, .slot, .source, .sourceDigest] | @tsv' \
        "${RELEASE_FILE}"
)

printf 'All eight source images passed provenance, digest, and release checks.\n'
