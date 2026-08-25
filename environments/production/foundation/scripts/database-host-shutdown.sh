#!/bin/bash

# Stops both PostgreSQL containers in parallel before Compute Engine replaces or shuts down the VM.

set -euo pipefail

containers=(
    agora-postgres-json-keys
    agora-postgres-authentication
)
pids=()

for container in "${containers[@]}"; do
    if docker container inspect "${container}" >/dev/null 2>&1; then
        docker stop --time 60 "${container}" >/dev/null &
        pids+=("$!")
    fi
done

status=0
for pid in "${pids[@]}"; do
    # A failed stop must not prevent the other PostgreSQL process from using
    # its shutdown window. Preserve a failure exit after both waits complete.
    wait "${pid}" || status=1
done

exit "${status}"
