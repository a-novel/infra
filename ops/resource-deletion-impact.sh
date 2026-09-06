#!/bin/bash

# Maps pull-request file metadata to the production roots whose plans can change.
# Usage: resource-deletion-impact.sh <pull-request-files.json>

set -euo pipefail

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s <pull-request-files.json>\n' "$0" >&2
    exit 64
fi

if [ ! -f "$1" ] || ! command -v jq >/dev/null 2>&1; then
    printf 'Pull-request file metadata is unavailable.\n' >&2
    exit 69
fi

if ! jq --exit-status '
    type == "array" and
    all(.[]; type == "object" and (.filename | type) == "string")
' "$1" >/dev/null; then
    printf 'Pull-request file metadata has an invalid shape.\n' >&2
    exit 65
fi

jq --compact-output '
  [
    .[]
    | .filename, (.previous_filename // empty)
    | select(type == "string")
  ] as $paths
  | (
      any($paths[];
        . == ".opentofu-version" or
        . == ".terraform.lock.hcl" or
        (
          test("(^|/)[^/]+\\.(tf|tf\\.json|tofu|tofu\\.json)$") and
          (startswith("bootstrap/") or
           startswith("environments/production/foundation/") or
           startswith("environments/production/release/") | not)
        )
      )
    ) as $all_roots
  | {
      required: (
        $all_roots or
        any($paths[];
          startswith("bootstrap/") or
          startswith("environments/production/foundation/") or
          startswith("environments/production/release/") or
          . == "deploy/production/images.yaml"
        )
      ),
      release_root: (
        $all_roots or
        any($paths[]; startswith("environments/production/release/"))
      ),
      release_manifest: any($paths[]; . == "deploy/production/images.yaml"),
      roots: (
        if $all_roots then
          ["bootstrap", "foundation", "release"]
        else
          [
            if any($paths[]; startswith("bootstrap/")) then "bootstrap" else empty end,
            if any($paths[]; startswith("environments/production/foundation/")) then "foundation" else empty end,
            if any($paths[];
              startswith("environments/production/release/") or
              . == "deploy/production/images.yaml"
            ) then "release" else empty end
          ]
        end
      )
    }
' "$1"
