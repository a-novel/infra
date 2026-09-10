#!/bin/sh

# Probe the tagged private candidate with the image's application health RPC.
# The metadata token and response stay inside this one-shot Cloud Run job.
set +x
set -eu

IDENTITY_TOKEN="$(wget -q -T 10 -O - --header='Metadata-Flavor: Google' "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=${JSON_KEYS_AUDIENCE:?}")"
test -n "${IDENTITY_TOKEN}"
export IDENTITY_TOKEN

# Header expansion keeps the token out of the command-line arguments.
# shellcheck disable=SC2016
grpcurl -connect-timeout 10 -max-time 30 -max-msg-sz 4096 -expand-headers -H 'Authorization: Bearer ${IDENTITY_TOKEN}' -d '{}' "${JSON_KEYS_CANDIDATE#https://}:443" anovel.jsonkeys.v2.StatusService/Status >/dev/null 2>&1
printf 'JSON Keys candidate application health passed.\n'
