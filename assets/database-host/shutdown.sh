#!/bin/bash

# Stops this host's PostgreSQL container before the VM shuts down.

set -euo pipefail

component="$(curl --fail --silent --show-error --connect-timeout 2 --max-time 10 --header 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/agora-database-service)"
case "${component}" in
    authentication|json-keys) ;;
    *) printf 'error: unsupported database service\n' >&2; exit 65 ;;
esac

container="agora-postgres-${component}"
if docker container inspect "${container}" >/dev/null 2>&1; then
    docker stop --time 60 "${container}" >/dev/null
fi
